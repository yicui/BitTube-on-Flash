package edu.vanderbilt.bittube.server.livestream
{
	import flash.events.Event;
	import flash.events.NetStatusEvent;
	import flash.filesystem.*;
	import flash.media.Video;
	import flash.net.FileFilter;
	import flash.net.GroupSpecifier;
	import flash.net.NetConnection;
	import flash.net.NetGroup;
	import flash.net.NetStream;
	import flash.utils.ByteArray;
	import mx.controls.Alert;
	
	public class MulticastStream extends Stream
	{
		private var netStream:NetStream; // NetStream for multicast
		private var metadataGroup:NetGroup; // NetGroup for metadata report
		private var nc:NetConnection; // NetConnection for local playback 
		private var ns:NetStream; // NetStream for local playback
		private var started:Boolean; // Whether the live ng is in progress
		private var http:HTTPDownloader; // Whether the source is HTTP or file
		private var file:File;
		private var fileStream:FileStream;
		private var progress:uint; // read progress of the file
		private var tags:Array; // circular array of tags
		private var tags_index:uint; // index of the tags array
		private var tags_circular_index:uint; // circular index of the tags array
		private var tags_beginning_timestamp:uint; // beginning timestamp of the tags array
		private var tags_beacon_timestamp:uint; // latest beacon timestamp in the tags array
		private var tags_adjust_timestamp:uint; // adjusting timestamp to stay synchronized with live ng
		private var special_video_tag:ByteArray; // the special starting video tag without which the playing cannot function
		private var special_audio_tag:ByteArray; // the special starting audio tag without which the playing cannot function
		private var output_buffer:ByteArray; // output buffer containing all tags to be multicast
		private var output_index:uint; // index for the output buffer for multicast 
		private var incomplete:uint; // mark which data item is incomplete
		private var tempsize:uint; // amount of data retrieved from the incomplete item  
		private var datasize:uint; // size of the latest data tag
		private var timestamp:uint; // timestamp of the latest data tag
		private var peerInfo:Array; // statistics info of peers
		private var countryInfo:Array; // statistics of regions peers belong to
		private var manager_:StreamManager; // Manager
		private var time:uint; // current time

		public function MulticastStream(manager:StreamManager)
		{
			this.manager_ = manager;
			this.time = 0;
			this.channel_name = null;
			Initialize();
		}
		public override function Start(urls:String, channelname:String, video:Video):void
		{
			if (this.started == true)
			{
				throw Error("直播进行中");
			}
			if ((channelname == null) || (channelname == ""))
			{
				throw Error("频道名称不得为空");	
			}
			this.channel_name = channelname;
			
			this.video = video;
			if ((urls == null) || (urls == ""))
			{
				this.http = null;
				var fileToOpen:File = new File();
				var txtFilter:FileFilter = new FileFilter("Video", "*.flv");	
				try 
				{
					fileToOpen.browseForOpen("Open", [txtFilter]);
					fileToOpen.addEventListener(Event.SELECT, fileSelected);
				}
				catch (error:Error)
				{
					throw Error("Start() "+error.message);
				}
			}
			else 
			{
				this.http = new HTTPDownloader(urls);
				ReadytoStream();
			}
		}
		public override function Stop():Boolean
		{
			if (this.started == false) return false;
			if (this.http != null) this.http.sock_.close();
			Initialize();
			if (this.video != null) this.ns.close();
			return true;
		}
		public override function JoinNetGroup():void
		{
			if (this.channel_name == null) return;
			var groupSpecifier:GroupSpecifier = new GroupSpecifier("haichuangmedia.com/"+this.channel_name);
			groupSpecifier.serverChannelEnabled = true;
			groupSpecifier.postingEnabled = true;
			groupSpecifier.routingEnabled = true;
			groupSpecifier.multicastEnabled = true;			
			groupSpecifier.objectReplicationEnabled = true;
			
			netStream = new NetStream(this.manager_.live_nc, groupSpecifier.groupspecWithAuthorizations());
			netStream.addEventListener(NetStatusEvent.NET_STATUS, netStreamHandler);
			netStream.publish("stream");
		}
		public override function JoinMetadataGroup():void
		{
			if (this.channel_name == null) return;
			var groupSpecifier:GroupSpecifier = new GroupSpecifier("bittube.vanderbilt.edu/"+this.channel_name);
			groupSpecifier.serverChannelEnabled = true;
			groupSpecifier.postingEnabled = true;
			groupSpecifier.routingEnabled = true;
			groupSpecifier.multicastEnabled = true;
			groupSpecifier.objectReplicationEnabled = true;
			
			metadataGroup = new NetGroup(this.manager_.live_nc, groupSpecifier.groupspecWithAuthorizations());
			metadataGroup.addEventListener(NetStatusEvent.NET_STATUS, metadataGroupHandler);			
		}
		private function Initialize():void
		{
			this.started = false;
			this.channel_name = null;
			this.netStream = null;
			this.metadataGroup = null;
			this.peerInfo = new Array;
			this.countryInfo = new Array;
			this.http = null;
		}
		private	function fileSelected(event:Event):void
		{
			// Get prepared to open the file
			this.file = File(event.target);
			ReadytoStream();
		}
		private	function ReadytoStream():void 
		{
			try 
			{
				// Write FLV header
				var piece:ByteArray = new ByteArray();
				piece.length = 13;
				piece[0] = 70;
				piece[1] = 76;
				piece[2] = 86;
				piece[3] = 1;
				piece[4] = 5;
				piece[5] = piece[6] = piece[7] = 0;
				piece[8] = 9;
				piece[9] = piece[10] = piece[11] = piece[12] = 0;
				
				// Start local video playback
				if (this.video != null)
				{
					var nsClient:Object = {};
					nsClient.onMetaData = ns_onMetaData;
					nsClient.onCuePoint = ns_onCuePoint;
					nc = new NetConnection();
					nc.connect(null);
					ns = new NetStream(nc);
					ns.client = nsClient;
					this.video.attachNetStream(ns);
					ns.play(null);
					ns.appendBytes(piece);
				}
				progress = 0;
				tags = new Array;
				output_index = tags_index = tags_circular_index = 0;
				tags_beginning_timestamp = tags_adjust_timestamp = tags_beacon_timestamp = 0;
				this.special_video_tag = this.special_audio_tag = null;
				this.output_buffer = new ByteArray();

				if (this.manager_.P2PReady()) 
				{
					JoinNetGroup();
					JoinMetadataGroup();
				}
				// Toggle the status
				started = true;
			}
			catch (error:Error)
			{
				Alert.show(error.message);
			}
		}
		public override function CheckUpdate(input_time:uint):uint 
		{
			if (this.started == false) return 0;
			this.time = input_time;
			ManagePeers();
			// In rare events where the data amount read in is too small, wait until the next time
			if (this.http == null)
			{
				fileStream = new FileStream();
				fileStream.open(file, FileMode.READ);
				fileStream.position = this.progress;
				if (fileStream.bytesAvailable < 1000) return 0;
			}
			else
			{
				if ((this.http.sock_.connected == false) || ((this.http.sock_.bytesAvailable < 1000) && (progress > 0)))
				{
					this.http.GetData();
					ReadytoStream();
					return 0;
				}
				if (this.http.sock_.bytesAvailable < 1000)	return 0; 
			}
			// Read all available data from file into buffer
			var buffer:ByteArray = new ByteArray();
			if (this.http == null) fileStream.readBytes(buffer);
			else this.http.sock_.readBytes(buffer);

			buffer.position = 0;
			// Read FLV header
			if (progress == 0)
			{
				var http_offset:uint = 0; 
				if (this.http != null)
				{
					try 
					{
						http_offset = this.http.ReadHTTPResponse(buffer);
					}
					catch (error:Error)
					{
						CloseStream();
						return 0;
					}
				}
				buffer.position = http_offset;
				var header:ByteArray = new ByteArray();
				buffer.readBytes(header, 0, 3);
				// Check if the file header is FLV header
				if ((header[0] != 70) || (header[1] != 76) || (header[2] != 86))
				{
					Alert.show("Wrong File Format: "+header[0]+header[1]+header[2]);
					CloseStream();
					return 0;
				}
				buffer.position = http_offset + 8;
				var offset:uint = buffer.readUnsignedByte();
				buffer.position = http_offset + offset + 4;
				incomplete = 0;
				if (this.http == null)
				{
					// Directly jump to the end of the file to keep up with live ng
					this.progress = file.size;
					return 0;
				}
			}
			// Read FLV body
			// incomplete = 0 means the tag is complete, incomplete = 1 means prefix is incomplete, 
			// incomplete = 2 means data is incomplete, incomplete = 3 means tag size is incomplete
			var tags_old_index:uint = tags_index;
			while (buffer.bytesAvailable > 0)
			{
				if (tags_circular_index >= tags.length)
				{
					var tag:ByteArray = new ByteArray();
					tags.push(tag);
				}
				// Tag prefix
				if (incomplete <= 1)
				{
					if (incomplete == 1)
						buffer.readBytes(tags[tags_circular_index], tempsize, 11-tempsize);
					else if (buffer.bytesAvailable >= 11)
						buffer.readBytes(tags[tags_circular_index], 0, 11);
					else if (buffer.bytesAvailable < 11)
					{
						tempsize = buffer.bytesAvailable;
						buffer.readBytes(tags[tags_circular_index], 0, tempsize);
						incomplete = 1;
						break;
					}
					// Tag Size
					datasize = 65536*tags[tags_circular_index][1]+256*tags[tags_circular_index][2]+tags[tags_circular_index][3];
					// Timestamp
					timestamp = 65536*tags[tags_circular_index][4]+256*tags[tags_circular_index][5]+tags[tags_circular_index][6]+16777216*tags[tags_circular_index][7];
					// If timestamp is smaller than previous tag, consider it an exception
					if (timestamp < tags_beginning_timestamp)
					{
						Alert.show("timestamp smaller than previous tag"+timestamp);
						CloseStream();
						return 0;
					}
					// Set the adjusting timestamp when the live ng starts
					if (tags_index == 0)
						tags_adjust_timestamp = timestamp;
					if (tags_circular_index == 0)
						tags_beginning_timestamp = tags_beacon_timestamp = timestamp;
				}
				// Tag data
				if (incomplete <= 2)
				{
					if (incomplete == 2)
					{
						if ((tempsize+buffer.bytesAvailable) < datasize)
						{
							var additional_tempsize:uint = buffer.bytesAvailable;
							buffer.readBytes(tags[tags_circular_index], tempsize+11, additional_tempsize);
							tempsize += additional_tempsize;
							break;
						}
						buffer.readBytes(tags[tags_circular_index], tempsize+11, datasize-tempsize);
					}
					else 
					{
						if (buffer.bytesAvailable < datasize)
						{
							tempsize = buffer.bytesAvailable;
							buffer.readBytes(tags[tags_circular_index], 11, tempsize);
							incomplete = 2;
							break;
						}
						buffer.readBytes(tags[tags_circular_index], 11, datasize);
					}
				}
				// Tag size
				if (incomplete == 3)
					buffer.readBytes(tags[tags_circular_index], 11+datasize+tempsize, 4-tempsize);
				else if (buffer.bytesAvailable >= 4)
					buffer.readBytes(tags[tags_circular_index], 11+datasize, 4);
				else if (buffer.bytesAvailable < 4)
				{
					tempsize = buffer.bytesAvailable;
					buffer.readBytes(tags[tags_circular_index], 11+datasize, tempsize);
					incomplete = 3;
					break;
				}
				tags[tags_circular_index].position = 11+datasize;
				var tagsize:uint = tags[tags_circular_index].readInt(); 
				// A safeguard to ensure we are reading file correctly (if a live FLV file has tagsize 0, fill it in)
				if (tagsize == 0)
				{
					tags[tags_circular_index].position = 11+datasize;
					tags[tags_circular_index].writeInt(datasize+11);
				}
				else if (tagsize != (datasize+11))
				{
					Alert.show("unfit tagsize "+tagsize);
					CloseStream();
					return 0;
				}
				// Adjust the timestamp to stay synchronized with the live ng
				if (tags_adjust_timestamp > 0)
				{
					var temp_timestamp:uint = timestamp - tags_adjust_timestamp;
					var bytes:ByteArray = new ByteArray();
					bytes.length = 4;
					bytes.writeInt(temp_timestamp);
					tags[tags_circular_index][4] = bytes[1];
					tags[tags_circular_index][5] = bytes[2];
					tags[tags_circular_index][6] = bytes[3];
					tags[tags_circular_index][7] = bytes[0];
				}
				// Finalize the total size of the tag, display it				
				tags[tags_circular_index].length = datasize+15;
				if (this.video != null) this.ns.appendBytes(tags[tags_circular_index]);
				// Catch the first seekable video tag as the special tag to begin the playback for every receiver
				if ((this.special_video_tag == null) && (tags[tags_circular_index][0] == 9) && ((tags[tags_circular_index][11] >> 4) == 1))
				{
					this.special_video_tag = new ByteArray();
					this.special_video_tag.writeBytes(tags[tags_circular_index]);
				}
				else if ((this.special_audio_tag == null) && (tags[tags_circular_index][0] == 8))
				{
					this.special_audio_tag = new ByteArray();
					this.special_audio_tag.writeBytes(tags[tags_circular_index]);
				}
				// Only after the special tags are found do we start the multicasting
				else if ((this.special_video_tag != null) && (this.special_audio_tag != null))
				{
					/*tags[tags_circular_index].length = datasize+19;
					tags[tags_circular_index].position = datasize+15;
					tags[tags_circular_index].writeInt(tags_index);
					netStream.send("Receive", tags[tags_circular_index]);*/				

					// Each buffer is a GOP whose starting tag is a seekable video tag
					if ((tags[tags_circular_index][0] == 9) && ((tags[tags_circular_index][11] >> 4) == 1) && (output_buffer.length > 0))
					{
						output_buffer.writeInt(output_index);
						netStream.send("Receive", output_buffer);
						output_index ++;
						output_buffer.length = 0;
					}
					output_buffer.writeBytes(tags[tags_circular_index], 0, datasize+15);
					// Keep 10 minutes of data
					if (timestamp > (tags_beginning_timestamp + 600000))
					{
						tags.length = tags_circular_index+1;
						tags_circular_index = 0;
					}
					else tags_circular_index ++;
					tags_index ++;
				}
				incomplete = 0;
			}
			progress += buffer.length;
			// advertise the special tags periodically
			if ((this.special_audio_tag != null) && (this.special_video_tag != null))
				this.metadataGroup.addHaveObjects(0, 1);
			if (this.http == null)	this.fileStream.close();
			return buffer.length;
		}
		public override function BroadcastID(ID:String):void
		{
			if (this.metadataGroup != null)
			{
				this.metadataGroup.post(ID);
			}
		}
		public override function DataBytesPerSecond():uint
		{
			if (this.netStream == null) return 0;
			return this.netStream.multicastInfo.sendDataBytesPerSecond;
		}
		public override function UserNumber():uint
		{
			if (this.metadataGroup == null) return 0;
			return Math.max(this.peerInfo.length, (this.metadataGroup.estimatedMemberCount-1));
		}
		public override function Delay():uint
		{
			if (this.peerInfo.length == 0) return 0;
			var delay:uint = this.peerInfo[0].delay;
			for (var i:uint = 1; i < this.peerInfo.length; i ++)
				delay += this.peerInfo[i].delay;
			return delay/this.peerInfo.length/1000;
		}
		public override function HTTPTime():uint
		{
			if (this.peerInfo.length == 0) return 0;
			var http_time:uint = this.peerInfo[0].http_time;
			for (var i:uint = 1; i < this.peerInfo.length; i ++)
				http_time += this.peerInfo[i].http_time;
			return http_time/this.peerInfo.length;
		}
		public override function NumInterruptions():Number
		{
			if (this.peerInfo.length == 0) return 0;
			var num_interruptions:uint = this.peerInfo[0].num_interruptions;
			for (var i:uint = 1; i < this.peerInfo.length; i ++)
				num_interruptions += this.peerInfo[i].num_interruptions;
			return Number(num_interruptions/this.peerInfo.length);
		}
		public override function symmetricNAT():uint
		{
			if (this.peerInfo.length == 0) return 0;
			var counter:uint = 0;
			for (var i:uint = 0; i < this.peerInfo.length; i ++)
				if (this.peerInfo[i].symmetric_NAT == true) counter ++;
			return counter;
		}
		public override function UserLocations():Array
		{
			return this.countryInfo;
		}
		private function CloseStream():void
		{
			if (this.http == null)
				this.fileStream.close();
			else
				this.http.sock_.close();
		}		
		private function ProcessMessage(message:Object):void
		{
			for (var i:uint = 0; i < this.peerInfo.length; i ++)
				if (this.peerInfo[i].ip_address == message.ip_address)
				{
					this.peerInfo[i].country = message.country;
					this.peerInfo[i].delay = message.delay;
					this.peerInfo[i].http_time = message.http_time;
					this.peerInfo[i].num_interruptions = message.num_interruptions;
					this.peerInfo[i].symmetric_NAT = message.symmetric_NAT;
					this.peerInfo[i].timestamp = this.time;
					return;
				}
			var obj:Object = new Object;
			obj.ip_address = message.ip_address;
			obj.country = message.country;
			obj.delay = message.delay;
			obj.http_time = message.http_time;
			obj.num_interruptions = message.num_interruptions;
			obj.symmetric_NAT = message.symmetric_NAT;			
			this.peerInfo.push(obj);
			// Update the country info
			for (i = 0; i < this.countryInfo.length; i ++)
				if (this.countryInfo[i]['text'] == message.country)
				{
					this.countryInfo[i]['value'] ++;
					return;
				}
			var country:Object = new Object;
			country['text'] = message.country;
			country['value'] = 1;
			this.countryInfo.push(country);			
		}
		private function ManagePeers():void
		{
			for (var i:int = this.peerInfo.length-1; i >= 0; i --)		
				if ((this.time-this.peerInfo[i].timestamp) >= 600000)
				{
					this.peerInfo.splice(i, 1);
					for (var j:uint = 0; j < this.countryInfo.length; j ++)
						if (this.countryInfo[j]['text'] == this.peerInfo[i].country)
						{
							this.countryInfo[j]['value'] --;
							if (this.countryInfo[j]['value'] <= 0)
								this.countryInfo.splice(j, 1);
							break;
						}
				}
		}
		private function netStreamHandler(event:NetStatusEvent):void
		{
			switch(event.info.code)
			{
				case "NetStream.Connect.Failed":
				case "NetStream.Connect.Rejected":
					JoinNetGroup();
					break;
				default:
					break;
			}
		}
		private function metadataGroupHandler(event:NetStatusEvent):void
		{
			switch(event.info.code)
			{
				case "NetGroup.Connect.Rejected":
				case "NetGroup.Connect.Failed":
					JoinMetadataGroup();
					break;
				case "NetGroup.SendTo.Notify":
					// All messages should be destined to the server, do nothing
					if(event.info.fromLocal == true)
						ProcessMessage(event.info.message.value);
					else
						this.metadataGroup.sendToNearest(event.info.message, event.info.message.destination);
					break;
				case "NetGroup.Replication.Request":
					if ((event.info.index == 0) && (this.special_video_tag != null))
						this.metadataGroup.writeRequestedObject(event.info.requestID, this.special_video_tag);
					else if ((event.info.index == 1) && (this.special_audio_tag != null))
						this.metadataGroup.writeRequestedObject(event.info.requestID, this.special_audio_tag);
					else
						this.metadataGroup.denyRequestedObject(event.info.requestID);
					break;
				default:
					break;
			}
		}		
		private function ns_onMetaData(item:Object):void 
		{
		}
		
		private function ns_onCuePoint(item:Object):void 
		{
		}		
	}
}
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
	import flash.net.NetGroupReplicationStrategy;
	import flash.net.NetStream;
	import flash.utils.ByteArray;
	
	import mx.controls.Alert;
	
	public class DownloadStream extends Stream
	{
		private var netGroup:NetGroup; // NetGroup for streaming
		private var metadataGroup:NetGroup; // NetGroup for metadata report		
		private var netGroup_status:uint; // status of NetGroup		
		private var nc:NetConnection; // NetConnection for local playback 
		private var ns:NetStream; // NetStream for local playback
		private var started:Boolean; // Whether the live broadcasting is in progress
		private var http:HTTPDownloader; // Whether the source is HTTP or file 
		private var file:File;
		private var fileStream:FileStream;
		private var progress:uint; // read progress of the file
		private var tags:Array; // circular array of tags
		private var tags_index:uint; // index of the tags array
		private var tags_circular_index:uint; // circular index of the tags array
		private var tags_beginning_timestamp:uint; // beginning timestamp of the tags array
		private var tags_beacon_timestamp:uint; // latest beacon timestamp in the tags array
		private var tags_adjust_timestamp:uint; // adjusting timestamp to stay synchronized with live broadcasting
		private var special_video_tag:ByteArray; // the special starting video tag without which the playing cannot function
		private var special_audio_tag:ByteArray; // the special starting audio tag without which the playing cannot function		
		private var incomplete:uint; // mark which data item is incomplete
		private var tempsize:uint; // amount of data retrieved from the incomplete item  
		private var datasize:uint; // size of the latest data tag
		private var timestamp:uint; // timestamp of the latest data tag
		private var manager_:StreamManager; // Manager
		
		public function DownloadStream(manager:StreamManager)
		{
			this.manager_ = manager;
			this.started = false;
			this.http = null;
		}
		public function Start():void
		{
			if (this.started == true) 
			{
				Alert.show("Broadcasting in Session");
				return;	
			}
			this.video = new Video(320, 240);			
			if ((this.manager_.url_ == null) || (this.manager_.url_ == ""))
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
					Alert.show("Start() "+error.message);
				}
			}
			else 
			{
				this.http = new HTTPDownloader(this.manager_.url_);
				ReadytoStream();
			}
		}
		public function Stop():void
		{
			if (this.started == false) return;
			if (this.http != null) this.http.sock_.close();
			this.started = false;
			this.http = null;
			ns.close();	
			Alert.show("Stop");
		}
		public function JoinNetGroup():void
		{
			var groupSpecifier:GroupSpecifier = new GroupSpecifier("bittube.vanderbilt.edu/");
			groupSpecifier.serverChannelEnabled = true;
			groupSpecifier.postingEnabled = true;
			groupSpecifier.routingEnabled = true;
			groupSpecifier.multicastEnabled = true;			
			groupSpecifier.objectReplicationEnabled = true;
			
			netGroup = new NetGroup(this.manager_.live_nc, groupSpecifier.groupspecWithAuthorizations());
			netGroup.addEventListener(NetStatusEvent.NET_STATUS, netGroupHandler);
			netGroup_status = 1; 
		}
		public function JoinMetadataGroup():void
		{
			var groupSpecifier:GroupSpecifier = new GroupSpecifier("bittube.vanderbilt.edu/");
			groupSpecifier.serverChannelEnabled = true;
			groupSpecifier.postingEnabled = true;
			groupSpecifier.routingEnabled = true;
			groupSpecifier.multicastEnabled = true;			
			groupSpecifier.objectReplicationEnabled = true;
			
			metadataGroup = new NetGroup(this.manager_.live_nc, groupSpecifier.groupspecWithAuthorizations());
			metadataGroup.addEventListener(NetStatusEvent.NET_STATUS, metadataGroupHandler);			
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
				
				this.progress = 0;
				tags = new Array;
				tags_index = tags_circular_index = 0;
				tags_beginning_timestamp = tags_adjust_timestamp = tags_beacon_timestamp = 0;
				this.special_video_tag = this.special_audio_tag = null;
				
				if (this.manager_.P2PReady()) 
				{
					JoinNetGroup();
					JoinMetadataGroup();
				}
				// Toggle the status
				this.started = true;
			}
			catch (error:Error)
			{
				Alert.show("ReadytoStream() "+error.message);
			}
		}
		public function CheckUpdate(input_time:uint):uint 
		{
			if (this.started == false) return 0;
			// In rare events where the data amount read in is too small to read in HTTP response and FLV header, wait until the next time
			if (this.http == null)
			{
				fileStream = new FileStream();
				fileStream.open(file, FileMode.READ);
				fileStream.position = this.progress;
				if (fileStream.bytesAvailable < 1000) return 0;
			}
			else
			{
				if (this.http.sock_.connected == false)
				{
					this.http.GetData();
					this.progress = 0;
					return 0;
				}
				if (this.http.sock_.bytesAvailable < 1000) return 0;
			}
			// Read all available data from file/socket into buffer
			var buffer:ByteArray = new ByteArray();
			if (this.http == null) fileStream.readBytes(buffer);
			else this.http.sock_.readBytes(buffer);
			buffer.position = 0;

			// Read HTTP response and FLV header
			if (this.progress == 0)
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
					// Directly jump to the end of the file to keep up with live broadcasting
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
					// Set the adjusting timestamp when the live broadcasting starts
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
				// A safeguard to ensure we are reading file correctly (sometimes a live FLV file has tagsize as 0)
				if ((tagsize != 0) && (tagsize != (datasize+11)))
				{
					Alert.show("unfit tagsize "+tagsize);
					CloseStream();
					return 0;
				}
				// Adjust the timestamp to stay synchronized with the live broadcasting
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
				ns.appendBytes(tags[tags_circular_index]);
				// then multicast it
				tags[tags_circular_index].length = datasize+19;
				tags[tags_circular_index].position = datasize+15;
				tags[tags_circular_index].writeInt(tags_index);
				// Distribute the acquired tags to NetGroup
				if (netGroup_status == 2)
				{
					netGroup.addHaveObjects(tags_old_index, tags_index-1);
				}				
				// Keep 10 minutes of data
				if (timestamp > (tags_beginning_timestamp + 600000))
				{
					tags.length = tags_circular_index+1;
					tags_circular_index = 0;
				}
				else tags_circular_index ++;
				// Send out beacon every half second				
				if (timestamp > (tags_beacon_timestamp + 500))
				{
					if (netGroup_status == 2)
						netGroup.post(tags_index);
					tags_beacon_timestamp = timestamp;
				}				
				tags_index ++;
				incomplete = 0;
			}
			this.progress += buffer.length;
			if (this.http == null)	this.fileStream.close();
			return buffer.length;
		}
		public function BroadcastID(ID:String):void
		{
		}
		public function Delay():uint
		{
			return 0;
		}	
		public function DataBytesPerSecond():uint
		{
			if (netGroup_status < 2) return 0;
			return this.netGroup.info.objectReplicationSendBytesPerSecond;
		}
		public function UserNumber():uint
		{
			if (netGroup_status < 2) return 0;
			return this.netGroup.estimatedMemberCount;
		}
		public function UserLocations():Array
		{
			var a:Array = new Array();
			return a;
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
			
		}
		private function netGroupHandler(event:NetStatusEvent):void
		{
			switch(event.info.code)
			{
				case "NetGroup.Connect.Success":
					// Current Flash player has a bug of not responding to NetGroup.Connect.Success. So we rely on NetGroup.Neighbor.Connect event,
					// which is also a good indicator that the peer has successfully joined the NetGroup 				
				case "NetGroup.Neighbor.Connect":
					// no need to initialize netgroup twice
					if (netGroup_status == 2) break;
					netGroup_status = 2;
					netGroup.replicationStrategy = NetGroupReplicationStrategy.LOWEST_FIRST;
					break;
				case "NetGroup.Connect.Rejected":
				case "NetGroup.Connect.Failed":
					netGroup_status = 0;
					break;
				case "NetGroup.Neighbor.Disconnect":
					break;
				case "NetGroup.Replication.Request":
					if ((event.info.index < tags_index)&& (event.info.index >= (tags_index-tags.length)))
						netGroup.writeRequestedObject(event.info.requestID, tags[(tags.length+event.info.index-tags_index+tags_circular_index)%tags.length]);
					else
						netGroup.denyRequestedObject(event.info.requestID);
					break;
				case "NetGroup.SendTo.Notify":
					// All messages should be destined to the server, do nothing
					if(event.info.fromLocal == true)
						ProcessMessage(event.info.message);
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
						ProcessMessage(event.info.message);
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
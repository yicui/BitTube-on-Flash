package edu.vanderbilt.bittube.player {
	
	import flash.net.*;
	import flash.utils.ByteArray;
	import flash.events.*;

	public class HTTPScheduler implements Scheduler {
		// properties set via constructor		
		private var live_nc:NetConnection; // NetConnection for connecting to RTMFP
		private var player_ns:NetStream; // NetStream for playback
		private var parameters:Object; // input paramerers from the player 
		// HTTP FLV downloading		
		private var netStream:NetStream; // NetStream for multicast
		private var netStream_status:uint; // status of NetGroup	
		private var metadataGroup:NetGroup; // NetGroup for metadata report 
		private var header:ByteArray; // FLV header
		private var tags:Array; // circular array of tags
		private var tags_index:uint; // index of the expected tag 
		private var tags_play_index:uint; // index of the tag to be played
		private var tags_circular_index:uint; // circular index of the tags array
		private var tags_beginning_timestamp:uint; // beginning timestamp of the tags array
		private var tags_adjust_timestamp:uint; // adjusting timestamp to stay synchronized with live broadcasting
		private var special_video_tag:ByteArray; // the special starting video tag without which the playing cannot function
		private var special_audio_tag:ByteArray; // the special starting audio tag without which the playing cannot function
		private var timestamp:uint; // timestamp of the latest data tag
		private var server_streaming:Boolean; // client-server mode
		// Time counter
		private var counter:uint;
		private var jam_counter:uint; // jam counter triggered by Jam function		
		// Statistics information to be sent to the server 
		private var statistics:Object;
		private var serverID:String; // peer ID of the server
		private var locationMonitor:LocationMonitor;
		
		public function HTTPScheduler(input_nc:NetConnection, input_ns:NetStream, input_parameters:Object):void
		{
			live_nc = input_nc;		player_ns = input_ns;	parameters = input_parameters;
			// Initialization
			jam_counter = counter = 0;			
			serverID = null;
			statistics = new Object();
			statistics.total_time =	statistics.http_time = statistics.num_interruptions = 0;
			statistics.symmetric_NAT = false;
			locationMonitor = new LocationMonitor();
			
			netStream = null;
			metadataGroup = null;
			server_streaming = false;
			special_video_tag = special_audio_tag = null;					
			// 0 is uninitialized; 1 is initialized but waiting for approval from Stratus; 
			// 2 is passing P2P dialog, 3 is joining NetStream; 4 is NetStream joined, 5 is first packet receive 
			netStream_status = 0;
			
			// Initialize FLV header
			header = new ByteArray();
			header.length = 13;
			header[0] = 70;
			header[1] = 76;
			header[2] = 86;
			header[3] = 1;
			header[4] = 5;
			header[5] = header[6] = header[7] = 0;
			header[8] = 9;
			header[9] = header[10] = header[11] = header[12] = 0;
			InitializeStream(null);
			// Initialize tag array
			tags = new Array;
			tags_index = tags_play_index = tags_circular_index = 0;
			tags_beginning_timestamp = tags_adjust_timestamp = 0;
					
		}
		public function ReportStatistics():void
		{
			if ((netStream == null) || (metadataGroup == null) || (serverID == null)) return;
			var message:Object = new Object();
			message.destination = metadataGroup.convertPeerIDToGroupAddress(serverID);
			message.source = live_nc.nearID;
			
			statistics.delay = Math.max((counter*1000 - timestamp), 0);
			var results = locationMonitor.Results();
			statistics.symmetric_NAT = results.symmetric_NAT; 
			statistics.ip_address = results.ip_address;
			statistics.country = results.country;
			
			message.value = statistics;
			metadataGroup.sendToNearest(message, message.destination);
		}
		public function PeriodicUpdate():void 
		{
			// If metadataGroup has not been connected, try it again
			if (netStream_status == 0) 
			{
				JoinMetadataGroup();
				return;
			}
			// If netStream has not been connected, try it again
			if (netStream_status == 2) 
			{
				JoinNetGroup();
				return;
			}
			if (netStream_status >= 2)
			{
				if (special_video_tag == null)
					metadataGroup.addWantObjects(0, 0);
				if (special_audio_tag == null)
					metadataGroup.addWantObjects(1, 1);
			}
			counter ++;
			// If jam counter exceeds patience level, it must be caused by either HTTP or P2P streaming
			if ((jam_counter > 0) && (counter >= (parameters.patience_interval+jam_counter)))
			{
				if (server_streaming == true)
				{
					InitializeStream(parameters.urls);
					statistics.http_time += counter;
				}
				else Restart(4);
				jam_counter = counter = 0;					
			}
				// Besides jam counter, we must also watch out for initial delay situation, where we have to start HTTP while waiting for P2P
			else if ((netStream_status < 5) && (counter > parameters.patience_interval) && (server_streaming == false))
			{
				InitializeStream(parameters.urls);
				server_streaming = true;
				counter = 0;
			}
		}
		public function Jam():void 
		{
			jam_counter = counter;
		}		
		public function Receive(packet:ByteArray):void
		{
			// Read out index
			packet.position = packet.length - 4; 
			var index:uint = packet.readInt();
			// Do not start playing until all special tags are found
			// To avoid mosaic effect, we further hold off playing until a seekable video tag is found
			// If in the future we want to aggregate multiple tags into mega-tag (for network efficiency), this approach might backfire,
			// since a seekable tag might be hidden in the middle of a meta-tag, making it difficult feed into the player 
			if (netStream_status < 5)
			{
				if ((special_video_tag != null) && (special_audio_tag != null) && (packet[0] == 9) && ((packet[11] >> 4) == 1))
				{
					if (server_streaming == true)
					{
						server_streaming = false;
						statistics.http_time += counter;
						InitializeStream(null);
					}						
					player_ns.appendBytes(special_video_tag);
					player_ns.appendBytes(special_audio_tag);
					tags_index = tags_play_index = index;
				}
				else
					return;
			}
			// If the arriving tag's timestamp is even earlier than tags_play_index, it suggests the server has restarted  
			if (index < tags_play_index)
			{
				// Since the server is restarted, the new special tags must have been generated, so we need to retrieve them again 
				special_video_tag = special_audio_tag = null;	
				Restart(4);
				return;
			}
			// In case of light arriving misorder of tags, buffer them
			else if (index < tags_index)
			{
				// If there is still space left in the circular array
				if ((tags_index-tags.length) <= index)
				{
					if (tags[(tags.length+index-tags_index+tags_circular_index)%tags.length] == null)
						tags[(tags.length+index-tags_index+tags_circular_index)%tags.length] = new ByteArray();
					tags[(tags.lengthevent.info.index-tags_index+tags_circular_index)%tags.length] = packet;
					tags[(tags.length+index-tags_index+tags_circular_index)%tags.length].length = packet.length-4;
					if (AdjustTimestamp((tags.length+index-tags_index+tags_circular_index)%tags.length) == false)
					{
						Restart(4);
						return;
					}
				}
				else return;
			}
			// Tags arrive in order
			else
			{
				// Extend circular array if necessary 
				if ((tags_circular_index+index-tags_index) >= tags.length)
				{
					var tag:ByteArray = new ByteArray();
					tags.length = tags_circular_index+index-tags_index+1;
					tags[tags_circular_index+index-tags_index] = tag;
				}
				// Clear out tags made obsolete by the newly arrived tag
				for (var i:uint = tags_circular_index; i < tags_circular_index+index-tags_index; i ++) 
					tags[i] = null;
				// Update tags_circular_index and tags_index 
				tags_circular_index += index - tags_index;
				tags_index = index + 1;
				// Read tag into the array
				tags[tags_circular_index] = packet;
				tags[tags_circular_index].length = packet.length-4;
				if (AdjustTimestamp(tags_circular_index) == false)
				{
					Restart(4);
					return;
				}
				// Keep 10 minutes of data for future functions such as instant replay
				if (timestamp > (tags_beginning_timestamp + parameters.playback_time*1000))
				{
					tags.length = tags_circular_index+1;
					tags_circular_index = 0;
					tags_beginning_timestamp = timestamp;
				}
				else tags_circular_index++;					
			}
			// Play all continuous tags until the latest 
			while ((tags_play_index < tags_index) && (tags[(tags.length+tags_play_index-tags_index+tags_circular_index)%tags.length] != null))
			{
				player_ns.appendBytes(tags[(tags.length+tags_play_index-tags_index+tags_circular_index)%tags.length]);
				tags_play_index ++;
			}
		}
		private function Restart(level:uint):void
		{
			// Level 0: after failure to join the metadatagroup, try to rejoin
			// Level 2: after failure to join the netgroup, try to rejoin
			// Level 4: do not rejoin the netgroup or metadatagroup
			// In any level, one needs to initialize the tag sequence
			tags.length = 0;
			tags_circular_index = 0;
			player_ns.appendBytesAction(NetStreamAppendBytesAction.RESET_BEGIN);
			player_ns.appendBytes(header);	
			counter = 0;
			// If playback has been started, this is counted as an interruption
			if (netStream_status == 5)
			{
				statistics.num_interruptions ++;
			}
			netStream_status = level;
		}		
		private function InitializeStream(u:String):void
		{
			player_ns.close();
			if (u == null)
			{
				player_ns.play(null);
				player_ns.appendBytes(header);
			}
			else player_ns.play(u);
		}			
		private function AdjustTimestamp(index:uint):Boolean
		{
			var offset:uint = 0;
			while (offset < tags[index].length)
			{
				var size:uint = 65536*tags[index][offset+1]+256*tags[index][offset+2]+tags[index][offset+3];
				timestamp = 65536*tags[index][offset+4]+256*tags[index][offset+5]+tags[index][offset+6]+16777216*tags[index][offset+7];
				// Set adjusting timestamp as the timestamp of the first tag
				if (netStream_status < 5)
				{
					tags_beginning_timestamp = tags_adjust_timestamp = timestamp;
					netStream_status = 5;
				}					
				// Adjust timestamp for playout 
				timestamp -= tags_adjust_timestamp;
				var bytes:ByteArray = new ByteArray();
				bytes.length = 4;
				bytes.writeInt(timestamp);
				tags[index][offset+4] = bytes[1];
				tags[index][offset+5] = bytes[2];
				tags[index][offset+6] = bytes[3];
				tags[index][offset+7] = bytes[0];
				offset += size+11;
				tags[index].position = offset;
				// If there is format error, restart the streaming
				var tagsize:uint = tags[index].readInt();
				if ((tagsize != (size+11)) && (tagsize != 0)) return false;
				offset += 4;
			}
			return true;
		}
		private function JoinNetGroup():void
		{
			var groupSpecifier:GroupSpecifier = new GroupSpecifier("bittube.vanderbilt.edu/"+parameters.channel_name);
			groupSpecifier.serverChannelEnabled = true;
			groupSpecifier.postingEnabled = true;
			groupSpecifier.routingEnabled = true;
			groupSpecifier.multicastEnabled = true;
			groupSpecifier.objectReplicationEnabled = true;
				
			netStream = new NetStream(live_nc, groupSpecifier.groupspecWithAuthorizations());
			netStream.addEventListener(NetStatusEvent.NET_STATUS, netGroupHandler);
			var d:Object = new Object;
			netStream.client = d;
			d.Receive = function (packet:ByteArray):void
			{
				Receive(packet);
			}
				
			netStream.play("stream");
			netStream_status = 3;
		}
		private function JoinMetadataGroup():void
		{
			var groupSpecifier:GroupSpecifier = new GroupSpecifier("bittube.vanderbilt.edu/"+parameters.channel_name);
			groupSpecifier.serverChannelEnabled = true;
			groupSpecifier.postingEnabled = true;
			groupSpecifier.routingEnabled = true;
			groupSpecifier.multicastEnabled = true;
			groupSpecifier.objectReplicationEnabled = true;
				
			metadataGroup = new NetGroup(live_nc, groupSpecifier.groupspecWithAuthorizations());
			metadataGroup.addEventListener(NetStatusEvent.NET_STATUS, netGroupHandler);				
			netStream_status = 1;
		}
		private function netGroupHandler(event:NetStatusEvent):void
		{
			switch (event.info.code)
			{
				case "NetStream.Connect.Success":
					if (netStream_status >= 4) break;
					netStream_status = 4;
					break;
				case "NetStream.Connect.Failed":
				case "NetStream.Connect.Rejected":
					Restart(2);
					break;
				case "NetGroup.Connect.Success":
				case "NetGroup.Neighbor.Connect":
					// no need to initialize netgroup twice
					if (netStream_status >= 2) break;
					netStream_status = 2;
					JoinNetGroup();
					break;
				case "NetGroup.Connect.Rejected":
				case "NetGroup.Connect.Failed":
					Restart(0);
					break;
				case "NetGroup.Posting.Notify":
					serverID = event.info.message;
				case "NetGroup.SendTo.Notify":
					// If there are messages destined to peers, do nothing
					if(event.info.fromLocal != true)
						metadataGroup.sendToNearest(event.info.message, event.info.message.destination);
					break;
				case "NetGroup.Replication.Fetch.Result":
					if (event.info.index == 0)
					{
						special_video_tag = new ByteArray();
						event.info.object.readBytes(special_video_tag);
						metadataGroup.addHaveObjects(0, 0);
						metadataGroup.removeWantObjects(0, 0);
					}
					else if (event.info.index == 1)
					{
						special_audio_tag = new ByteArray();
						event.info.object.readBytes(special_audio_tag);
						metadataGroup.addHaveObjects(1, 1);
						metadataGroup.removeWantObjects(1, 1);
					}
					break;
				case "NetGroup.Replication.Request":
					if ((event.info.index == 0) && (special_video_tag != null))
						metadataGroup.writeRequestedObject(event.info.requestID, special_video_tag);
					else if ((event.info.index == 1) && (special_audio_tag != null))
						metadataGroup.writeRequestedObject(event.info.requestID, special_audio_tag);
					else
						metadataGroup.denyRequestedObject(event.info.requestID);
					break;
				default:
					break;
			}
		}			
	}
}
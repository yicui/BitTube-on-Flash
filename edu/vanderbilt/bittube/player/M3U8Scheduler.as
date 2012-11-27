package edu.vanderbilt.bittube.player 
{
	import flash.events.*;
	import flash.net.*;
	import flash.utils.ByteArray;
		
	public class M3U8Scheduler implements Scheduler {
		private const http_download_buffer:uint = 1;
		private const quality_switching_threshold:uint = 60; // stay at least 60 seconds before switching to higher quality
		private const playlist_refresh_threshold:uint = 20; // refresh the playlist if the remaining time is less than 20 seconds
		// properties set via constructor
		private var live_nc:NetConnection; // NetConnection for connecting to RTMFP
		private var player_ns:NetStream; // NetStream for playback		
		private var parameters:Object; // input paramerers from the player
		// M3U8 downloading
		private var download_status:uint; // status of downloading
		private var downloaded:Object; // queue for tags downloaded but not yet played
		private var waiting:Object; // queue for tags waiting to be downloaded
		private var qualities:Array; // array for different quality versions 
		private var current_quality:Object; // current quality 
		private var default_time_length:uint; // queue for tags waiting to be downloaded
		private var playlist_counter:uint; // counter of the last the playlist is requested		
		private var play_counter:uint; // time counter to which the playback will sustain 
		private var http_counter:uint; // counter to calculate HTTP downloading time
		private var http_speed:uint; // seconds it takes to download a tag via HTTP
		private var http_index:uint; // index of the tag downloaded via HTTP, 0 means the downloading is finished
		private var play_index:uint; // index of the tag just played
		private var post_index:uint; // index of the tag last posted in the P2P group
		private var http_quality:Object; // quality of the tag deownloaded via HTTP 
		private var playlistloader:URLLoader; // loader to fetch playlist
		private var httploader:URLLoader; // loader to fetch video via HTTP
		private var xmlloader:URLLoader; // loader to fetch XML data
		private var playlist_name:String; // playlist name
		// Time counter
		private var counter:uint;
		private var jam_counter:uint; // jam counter triggered by Jam function
		// Statistics information to be sent to the server 
		private var statistics:Object;
		private var serverID:String; // peer ID of the server
		private var locationMonitor:LocationMonitor;
		
		public function M3U8Scheduler(input_nc:NetConnection, input_ns:NetStream, input_parameters:Object):void
		{
			live_nc = input_nc;		player_ns = input_ns;	parameters = input_parameters;
			// Initialization
			jam_counter = counter = 0;			
			playlist_counter = http_counter = play_counter = http_speed = http_index = play_index = post_index = 0;
			serverID = null;
			statistics = new Object();
			statistics.total_time =	statistics.http_time = statistics.num_interruptions = 0;
			statistics.symmetric_NAT = false;
			locationMonitor = new LocationMonitor();

			// 0 is nothing downloaded since the streaming is restartd; 1 is downloaded via HTTP; 2 is at least one tag via P2P 
			download_status = 0;

			// downloaded and waiting queues are carefully maintained such that both queues are sorted and no identcal indices exist in both queues combined 
			waiting = new Object;		waiting.tags = new Array;
			downloaded = new Object;	downloaded.tags = new Array;
			waiting.time_length = waiting.tags.length = downloaded.time_length = downloaded.tags.length = 0;
				
			qualities = new Array;
			AddQuality(parameters.urls, 0); 
			http_quality = current_quality = qualities[0];		current_quality.tried ++;		
			default_time_length = 10;			
		}
		public function Playback(time:uint):void
		{
			var timeleft:uint = downloaded.time_length;
			for (var i:uint = 0; timeleft > time; i ++)
				timeleft -= downloaded.tags[i].time_length;
			player_ns.close();		player_ns.play(null);		play_counter = counter;
			for (; i < downloaded.tags.length; i ++)
			{
				player_ns.appendBytesAction(NetStreamAppendBytesAction.RESET_BEGIN);
				player_ns.appendBytes(downloaded.tags[i].data);
				play_counter += downloaded.tags[i].time_length;
				if (play_index <= downloaded.tags[i].index) break;				
			}			
		}
		private function AddQuality(playlisturls:String, bandwidth:uint):void
		{
			// multiple playlists are sorted by ascending order of bandwidth
			for (var i:uint = 0; i < qualities.length; i ++)
				if (qualities[i].bandwidth < bandwidth) break;
			if (i == qualities.length) qualities.push(new Object); 
			else qualities.splice(i, 0, new Object);
			
			// 0 is uninitialized; 1 is playlist received; 
			// 2 is P2P initialized but waiting for approval from Stratus; 3 is approved;
			qualities[i].netGroup_status = 0;
			qualities[i].channel_name = qualities[i].metadataGroup = null;
			qualities[i].playlisturls = playlisturls;
			qualities[i].bandwidth = bandwidth;
			qualities[i].tried = qualities[i].smooth_since = 0;
		}
		private function RemoveQuality(quality:Object):void
		{
			for (var i:int = qualities.length-1; i >= 0; i --)
				if (qualities[i] == quality)
				{
					if (qualities[i] == current_quality) current_quality = null;
					qualities.splice(i, 1);
				}
		}
		private function SwitchQuality(quality:Object, smooth_since:uint):void
		{
			if (current_quality == quality) return;
			// At any time, only one netGroup is active, while others remain the initial state 
			if ((current_quality != null) && (current_quality.metadataGroup != null))
			{
				if (waiting.tags.length > 0)
					current_quality.metadataGroup.removeWantObjects(waiting.tags[0].index, waiting.tags[waiting.tags.length-1].index);
				if (downloaded.tags.length > 0)
					current_quality.metadataGroup.removeHaveObjects(downloaded.tags[0].index, downloaded.tags[downloaded.tags.length-1].index);
				current_quality.metadataGroup.removeEventListener(NetStatusEvent.NET_STATUS, netGroupHandler);
				current_quality.metadataGroup = current_quality.channel_name = null;
				current_quality.netGroup_status = 0;
			}				
			current_quality = quality;		current_quality.tried ++;	current_quality.smooth_since = smooth_since;
			GetPlaylist(current_quality.playlisturls);
		}
		private function JoinMetadataGroup(quality:Object):void
		{
			var groupSpecifier:GroupSpecifier = new GroupSpecifier("bittube.vanderbilt.edu/"+quality.channel_name);
			groupSpecifier.serverChannelEnabled = true;
			groupSpecifier.postingEnabled = true;
			groupSpecifier.routingEnabled = true;
			groupSpecifier.objectReplicationEnabled = true;
			
			quality.metadataGroup = new NetGroup(live_nc, groupSpecifier.groupspecWithAuthorizations());
			quality.metadataGroup.addEventListener(NetStatusEvent.NET_STATUS, netGroupHandler);				
			quality.netGroup_status = 2;
		}
		public function ReportStatistics():void
		{
			if ((current_quality.netGroup_status < 3) || (serverID == null)) return;
			var message:Object = new Object();
			message.destination = current_quality.metadataGroup.convertPeerIDToGroupAddress(serverID);
			message.source = live_nc.nearID;

			var results = locationMonitor.Results();
			statistics.symmetric_NAT = results.symmetric_NAT; 
			statistics.ip_address = results.ip_address;
			statistics.country = results.country;			
			
			message.value = statistics;
			current_quality.metadataGroup.sendToNearest(message, message.destination);
		}
		private function GetPlaylist(playlist:String):void
		{
			playlist_counter = counter;			
			//playlist = playlist+"?random="+Math.random();			
			try
			{
				playlistloader = new URLLoader(new URLRequest(playlist));
			}
			catch (error:Error)
			{
				
			}						
			playlistloader.addEventListener(IOErrorEvent.IO_ERROR, playlisterrorHandler);
			playlistloader.addEventListener(Event.COMPLETE, playlistloaderCompleteHandler);
		}
		private function InsertWaiting(clip_index:uint, time_length:uint):void
		{
			// No need to download tags already missing the play deadline			
			if (clip_index <= play_index) return;			
			for (var i:uint = 0; i < waiting.tags.length; i ++)
				if (waiting.tags[i].index >= clip_index) break;
			waiting.time_length += time_length;
			if (i == waiting.tags.length) waiting.tags.push(new Object);
			else if (waiting.tags[i].index == clip_index) waiting.time_length -= time_length;
			else waiting.tags.splice(i, 0, (new Object));
			waiting.tags[i].index = clip_index;
			waiting.tags[i].time_length = time_length;
			waiting.tags[i].data = null;
			waiting.tags[i].quality = current_quality;		
		}
		private function ReadNumber(playlist:String, index:uint):uint 
		{
			var result:uint = 0;
			while ((index < playlist.length) && ((playlist.charCodeAt(index) < 48) || (playlist.charCodeAt(index) > 57)))
				index ++;
			if (index == playlist.length) return 0;
			while ((index < playlist.length) && (playlist.charCodeAt(index) >= 48) && (playlist.charCodeAt(index) <= 57))
			{
				result = result * 10 + playlist.charCodeAt(index) - 48;
				index ++;
			}
			return result;
		}
		private function DownloadTag():void
		{
			// Always try to download the tag that needs to be played immediately
			if (waiting.tags.length == 0)
			{
				if ((counter-playlist_counter) >= playlist_refresh_threshold/4) GetPlaylist(current_quality.playlisturls);
				return;	
			}
			http_index = waiting.tags[0].index;		http_quality = waiting.tags[0].quality; 
			http_counter = counter;
			try
			{
				httploader = new URLLoader(new URLRequest(waiting.tags[0].quality.channel_name+http_index+".flv"));
			}
			catch (error:Error)
			{
			}			
			httploader.dataFormat = URLLoaderDataFormat.BINARY;
			httploader.addEventListener(IOErrorEvent.IO_ERROR, httperrorHandler);
			httploader.addEventListener(Event.COMPLETE, httploaderCompleteHandler);
		}			
		private function NewTag(index:uint, object:ByteArray, quality:Object):void
		{
			var tag:Object = null;
			// Remove the tag bearing the index value from the waiting queue
			for (var i:uint = 0; i < waiting.tags.length; i ++)
				if (waiting.tags[i].index == index)
				{
					waiting.time_length -= waiting.tags[i].time_length;
					if (waiting.time_length < playlist_refresh_threshold) GetPlaylist(current_quality.playlisturls);
					tag = (waiting.tags.splice(i, 1))[0];
					break;
				}
			// Try to search it in the downloaded queue. If it turns out a duplicate tag, simply ignore it. 
			for (var j:uint = 0; j < downloaded.tags.length; j ++)
				if (downloaded.tags[j].index >= index) break;
			if ((j < downloaded.tags.length) && (downloaded.tags[j].index == index)) return;
			// If the tag cannot be found in the waiting queue, it might be due to the failure of timely m3u8 retrieval, simply create a tag   
			if (tag == null)
			{
				tag = new Object;			tag.index = index;		tag.time_length = default_time_length;					
			}
			// If object is null or does not have a valid FLV header, simply remove the tag from the waiting queue
			if ((object != null) && (object.length > 12) && (object[0] == 70) && (object[1] == 76) && (object[2] == 86))
			{
				// If an incomplete FLV file, try to retrieve as many tags as possible 
				object.position = 8;
				var offset:uint = object.readUnsignedByte();
				object.position = offset + 4;
				while (object.bytesAvailable > 0)
				{
					if (object.bytesAvailable < 11)
					{
						object.length -= object.bytesAvailable; 	break; 
					}
					offset += 15+65536*object[offset+5]+256*object[offset+6]+object[offset+7];
					if ((offset+4) > object.length) 
					{
						object.length -= object.bytesAvailable;
					}
					else object.position = offset + 4;
				}
				tag.data = object;		tag.quality = quality;
				if (j == downloaded.tags.length) downloaded.tags.push(tag);
				else downloaded.tags.splice(j, 0, tag);
				
				downloaded.time_length += tag.time_length;
				statistics.total_time += tag.time_length;
			}
			// play all playable tags 
			if (i == 0)
			{
				if (waiting.tags.length > 0) tag = waiting.tags[0];
				else if (downloaded.tags.length > 0) tag = downloaded.tags[downloaded.tags.length-1];
				// If the first playable tag received since streaming is restarted, initialize the play counter 
				if (download_status == 0) play_counter = counter;					
				while ((j < downloaded.tags.length) && (downloaded.tags[j].index <= tag.index))
				{
					if (downloaded.tags[j].index > play_index)
					{
						player_ns.appendBytesAction(NetStreamAppendBytesAction.RESET_BEGIN);
						player_ns.appendBytes(downloaded.tags[j].data);
						play_counter += downloaded.tags[j].time_length;
						play_index = downloaded.tags[j].index;
					}
					j ++;							
				}
			}
			if (current_quality.netGroup_status >= 3)
			{
				current_quality.metadataGroup.removeWantObjects(index, index);
				if (object != null) current_quality.metadataGroup.addHaveObjects(index, index);
			}
			// Keep the size of the downloaded queue within playback threshold
			while ((downloaded.time_length > parameters.playback_time) && (downloaded.tags[0].index < tag.index))
			{
				downloaded.time_length -= downloaded.tags[0].time_length;
				if (current_quality.netGroup_status >= 3)
					current_quality.metadataGroup.removeHaveObjects(downloaded.tags[0].index, downloaded.tags[0].index);
				downloaded.tags.splice(0, 1);
			}
		}
		public function PeriodicUpdate():void 
		{
			if (current_quality.netGroup_status < 1)
			{
				GetPlaylist(current_quality.playlisturls);
				return;
			}
			// If metadataGroup has not been connected, try it again
			if (current_quality.netGroup_status < 2)
			{
				JoinMetadataGroup(current_quality);
				return;
			}
			counter ++;
			// If nothing is downloaded at the begining and patience level is exceeded, switch to HTTP 
			if (download_status == 0)
			{
				if ((counter > parameters.patience_interval) && (http_index == 0))	DownloadTag();	
			}
			// If jam counter exceeds patience level, use HTTP if it haasn't been started
			else if ((jam_counter > 0) && (counter >= (parameters.patience_interval+jam_counter)))
			{
				jam_counter = 0;
				// If the P2P doesn't catch up, give HTTP a chance  
				if (download_status == 2)
				{
					// No need to request via HTTP more than once
					if (http_index == 0)
					{
						download_status = 0;	current_quality.smooth_since = counter;
						DownloadTag();	
					}
				}
				else // download_status == 1, which means HTTP doesn't catch up and we should lower quality if there is one
				{
					for (var i:uint = 0; i < qualities.length; i ++)
						if ((qualities[i] == current_quality) && (i < (qualities.length-1)))
						{
							SwitchQuality(qualities[i+1], counter);	break;
						}
				}
			}
			else
			{
				// If it has been smooth play for a while, try a higher quality
				// We should be conservative more and more as we multiple the switching overhead by the number of times we have tried 
				if ((counter - current_quality.smooth_since) > current_quality.tried * quality_switching_threshold) 
				{
					for (i = 0; i < qualities.length; i ++)
						if ((qualities[i] == current_quality) && (i > 0) && ((counter - current_quality.smooth_since) > qualities[i-1].tried * quality_switching_threshold))
						{
							SwitchQuality(qualities[i-1], counter);	break;
						}
				}
				// If the last tag is downloaded via HTTP (a good indication that P2P is unavailable), 
				// try to get the next tag via HTTP just before the remaining time is too short to cause interruption  
				if ((download_status == 1) && (http_index == 0) && (http_speed >= (play_counter - counter)))
					DownloadTag();
			}
		}
		public function Jam():void 
		{
			jam_counter = counter;
		}
		private function netGroupHandler(event:NetStatusEvent):void
		{
			switch (event.info.code)
			{
				case "NetGroup.Connect.Success":
				case "NetGroup.Neighbor.Connect":
					// no need to initialize netgroup twice
					if (current_quality.netGroup_status >= 3) break;
					current_quality.netGroup_status = 3;
					current_quality.metadataGroup.replicationStrategy = NetGroupReplicationStrategy.LOWEST_FIRST;
					if (waiting.tags.length > 0)
						current_quality.metadataGroup.addWantObjects(waiting.tags[0].index, waiting.tags[waiting.tags.length-1].index);
					for (var i:uint = 0; i < downloaded.tags.length; i ++)
						if (downloaded.tags[i].quality == current_quality)
							current_quality.metadataGroup.addHaveObjects(downloaded.tags[i].index, downloaded.tags[i].index);
					break;
				case "NetGroup.Connect.Rejected":
				case "NetGroup.Connect.Failed":
					current_quality.netGroup_status = 0;
					break;
				case "NetGroup.Posting.Notify":
					switch (event.info.message.type)
					{
						case "serverID": 
							serverID = event.info.message.value;
							break;
						case "m3u8":
							for (i = 0; i < event.info.message.value.length; i ++)
								InsertWaiting(event.info.message.value[i].index, event.info.message.value[i].time_length);
							if (waiting.tags.length > 0)
							{
								current_quality.metadataGroup.addWantObjects(waiting.tags[0].index, waiting.tags[waiting.tags.length-1].index);
								if (waiting.tags[waiting.tags.length-1].index > post_index)										
									post_index = waiting.tags[waiting.tags.length-1].index;
							}
							break;
						default: break;
					}
					break;
				case "NetGroup.SendTo.Notify":
					// If there are messages destined to peers, do nothing
					if (event.info.fromLocal != true)
						current_quality.metadataGroup.sendToNearest(event.info.message, event.info.message.destination);
					break;
				case "NetGroup.Replication.Fetch.Result":
					NewTag(event.info.index, ByteArray(event.info.object), current_quality);
					download_status = 2;
					break;
				case "NetGroup.Replication.Request":
					if ((downloaded.tags.length > 0) && (event.info.index <= downloaded.tags[downloaded.tags.length-1].index) && (event.info.index >= downloaded.tags[0].index))
					{
						for (i = 0; i < downloaded.tags.length; i ++)
							if ((downloaded.tags[i].index == event.info.index) && (downloaded.tags[i].quality == current_quality))
							{
								current_quality.metadataGroup.writeRequestedObject(event.info.requestID, downloaded.tags[i].data);
								break;									
							}
						if (i == downloaded.tags.length) current_quality.metadataGroup.denyRequestedObject(event.info.requestID);
					}
					else current_quality.metadataGroup.denyRequestedObject(event.info.requestID);
					break;
				default:
					break;
			}
		}
		private function playlisterrorHandler(event:IOErrorEvent):void
		{
		}
		private function playlistloaderCompleteHandler(event:Event):void
		{
			var playlist:String = String(playlistloader.data);
			var index:int = playlist.indexOf("#EXTM3U");
			if (index == -1) return;
			var end_index:uint; 				
			// if a variant playlist, then read off more playlists
			index = playlist.indexOf("#EXT-X-STREAM-INF:");
			if (index != -1)
			{
				// since the variant playlist does not contain any media sequence, remove it from the downloaded queue 
				RemoveQuality(current_quality);
				while (index != -1)
				{
					// bandwidth
					index = playlist.indexOf("BANDWIDTH", index);
					var bandwidth:uint = 0;
					if (index != -1)	bandwidth = ReadNumber(playlist, index);
					// URI of the playlist within the variant playlist
					index = playlist.indexOf("http://", index);
					if (index == -1) break;
					end_index = playlist.indexOf(".m3u8", index);
					if (end_index == -1) break;
					AddQuality(playlist.substring(index, end_index+5), bandwidth);
					// next round
					index = playlist.indexOf("#EXT-X-STREAM-INF:", index);
				}
				if (qualities.length > 0)	SwitchQuality(qualities[0], counter);
				return;
			}
			// A normal playlist
			// default duration of the clip
			index = playlist.indexOf("#EXT-X-TARGETDURATION:");
			if (index != -1) default_time_length = ReadNumber(playlist, index);
			index = playlist.indexOf("#EXTINF:");
			while (index != -1)
			{
				// duration of the clip
				var time_length:uint = ReadNumber(playlist, index);
				if (time_length == 0) time_length = default_time_length;
				// index of the clip
				index = playlist.indexOf("http://", index);
				if (index == -1) break;
				end_index = playlist.indexOf(".flv", index);
				if (end_index == -1) break;
				else end_index --;
				var clip_index:uint = 0;
				var i:uint = 0;
				// Read in the number in the reverse order, it should not be too big to exceed 32-bit value limit
				while ((playlist.charCodeAt(end_index) >= 48) && (playlist.charCodeAt(end_index) <= 57) && (i < 8))
				{
					clip_index = clip_index + (playlist.charCodeAt(end_index) - 48)*Math.pow(10, i);
					end_index --;	i ++;
				}
				if ((clip_index == 0) || (end_index <= index)) break;
				// Do not redownload clips that have been already downloaded
				if ((downloaded.tags.length > 0) && (clip_index <= downloaded.tags[downloaded.tags.length-1].index))
				{
					index = playlist.indexOf("#EXTINF:", index);
					continue;
				}				
				// URI of the clip
				var clip_indexstring:String = playlist.substr(end_index+1, i);
				if (current_quality.channel_name == null)
					current_quality.channel_name = playlist.substring(index, end_index+1);
				// Insert into the waiting queue if the index is never seen in the downloaded queue or waiting queue
				InsertWaiting(clip_index, time_length);
				// next round
				index = playlist.indexOf("#EXTINF:", index);
			}
			if (waiting.tags.length > 0)
			{
				if (current_quality.netGroup_status == 0)	current_quality.netGroup_status = 1;
				if (current_quality.netGroup_status >= 3)	
				{
					current_quality.metadataGroup.addWantObjects(waiting.tags[0].index, waiting.tags[waiting.tags.length-1].index);
					if (waiting.tags[waiting.tags.length-1].index > post_index)		
					{
						var obj:Object = new Object;	
						obj.type = "m3u8";		obj.value = new Array(waiting.tags.length);
						for (i = 0; i < waiting.tags.length; i ++)
						{
							obj.value[i] = new Object;
							obj.value[i].index = waiting.tags[i].index;
							obj.value[i].time_length = waiting.tags[i].time_length;
						}
						current_quality.metadataGroup.post(obj);
						post_index = waiting.tags[waiting.tags.length-1].index;
					}
				}
			}
			// If we fail to get anything from the playlist, it must be a failure (either getting the old playlist again or the server not responding)
			// In this case, we simply guess the index of the next flv file. If the file name turns out to be wrong, we just simply delete it from the waiting list
			// Also since this is quite a risky move and against the m3u8 specification, we won't broadcast it to the P2P group
			/*else if ((downloaded.tags.length > 1) && (current_quality.netGroup_status >= 3))
			{
				index = 2*downloaded.tags[downloaded.tags.length-1].index - downloaded.tags[downloaded.tags.length-2].index;
				InsertWaiting(index, downloaded.tags[downloaded.tags.length-1].time_length);
				current_quality.metadataGroup.addWantObjects(index, index);
			}*/
		}
		private function httperrorHandler(event:IOErrorEvent):void
		{				
			NewTag(http_index, null, http_quality);
			http_index = 0;
		}
		private function httploaderCompleteHandler(event:Event):void
		{
			if ((waiting.tags.length > 0) && (http_index == waiting.tags[0].index)) 
			{
				statistics.http_time += waiting.tags[0].time_length;
				// If the bandwidth item is missing, fill it in with the measured result and resort the quality array
				if (current_quality.bandwidth == 0)
				{
					current_quality.bandwidth = httploader.data.length/waiting.tags[0].time_length;
					for (var i:uint = 0; i < qualities.length; i ++)
						if (qualities[i] == current_quality) break;
					for (i = i+1; i < qualities.length; i ++)
						if (current_quality.bandwidth > qualities[i].bandwidth) qualities[i-1] = qualities[i];
						else
						{
							qualities[i] = current_quality;	break;
						}
				}
			}
			NewTag(http_index, ByteArray(httploader.data), http_quality);
			if (download_status == 0) download_status = 1;
			// Calculate speed of the latest HTTP downloading
			http_speed = counter - http_counter + http_download_buffer;
			http_index = 0;
		}
	}
}
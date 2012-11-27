package edu.vanderbilt.bittube.server.livestream
{
	import flash.events.*;
	import flash.media.Video;
	import flash.net.*;
	
	public class M3U8Stream extends Stream 
	{
		private var started:Boolean; // Whether the live ng is in progress
		private var playlistloader:URLLoader; // loader to fetch playlist
		private var peerInfo:Array; // statistics info of peers
		private var countryInfo:Array; // statistics of regions peers belong to
		private var manager_:StreamManager; // Manager
		private var qualities:Array; // array for different quality versions
		private var current_quality:Object; // current quality
		private var time:uint; // current time
		private var http_traffic:uint;
		private var total_traffic:uint;

		public function M3U8Stream(manager:StreamManager)
		{
			this.manager_ = manager;
			this.time = 0;
			this.channel_name = null;
			Initialize();
		}
		public override function Start(urls:String, channelname:String, video:Video):void
		{
			if (this.started == true) 
				throw Error("直播进行中");
			if ((channelname == null) || (channelname == ""))
				throw Error("频道名称不得为空");	
			if ((urls == null) || (urls == ""))
				throw Error("playlist地址不得为空");
			this.channel_name = channelname;
			this.video = video;
			AddQuality(urls, 0);	current_quality = qualities[0];	
			GetPlaylist(urls);
		}
		public override function Stop():Boolean
		{
			if (this.started == false) return false;
			Initialize();
			return true;
		}
		private function GetPlaylist(playlist:String):void
		{
			try
			{
				playlistloader = new URLLoader(new URLRequest(playlist+"?random="+Math.random()));
			}
			catch (error:Error)
			{
				
			}						
			playlistloader.addEventListener(IOErrorEvent.IO_ERROR, playlisterrorHandler);
			playlistloader.addEventListener(Event.COMPLETE, playlistloaderCompleteHandler);
		}		
		private function AddQuality(playlisturls:String, bandwidth:uint):void
		{
			// multiple playlists are sorted by ascending order of bandwidth
			for (var i:uint = 0; i < qualities.length; i ++)
				if (qualities[i].bandwidth < bandwidth) break;
			if (i == qualities.length) qualities.push(new Object); 
			else qualities.splice(i, 0, new Object);
			
			qualities[i].channel_name = qualities[i].metadataGroup = null;
			qualities[i].playlisturls = playlisturls;
			qualities[i].bandwidth = bandwidth;
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
		private function JoinM3U8Group(quality:Object):void
		{
			var groupSpecifier:GroupSpecifier = new GroupSpecifier("bittube.vanderbilt.edu/"+quality.channel_name);
			groupSpecifier.serverChannelEnabled = true;
			groupSpecifier.postingEnabled = true;
			groupSpecifier.routingEnabled = true;
			groupSpecifier.objectReplicationEnabled = true;
			
			quality.metadataGroup = new NetGroup(this.manager_.live_nc, groupSpecifier.groupspecWithAuthorizations());
			quality.metadataGroup.addEventListener(NetStatusEvent.NET_STATUS, metadataGroupHandler);				
		}
		private function Initialize():void
		{
			this.channel_name = null;
			this.started = false;
			this.peerInfo = new Array;
			this.countryInfo = new Array;
			this.qualities = new Array;
		}
		public override function CheckUpdate(input_time:uint):uint 
		{
			if (this.started == false) return 0;
			this.time = input_time;
			ManagePeers();
			return total_traffic/this.peerInfo.length;
		}
		public override function BroadcastID(ID:String):void
		{
			var obj:Object = new Object;
			obj.type = "serverID";
			obj.value = ID;
			for (var i:uint = 0; i < qualities.length; i ++)
				if (qualities[i].metadataGroup != null)
					qualities[i].metadataGroup.post(obj);
		}
		public override function DataBytesPerSecond():uint
		{
			return http_traffic;
		}
		public override function UserNumber():uint
		{
			return this.peerInfo.length;
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
		private function ProcessMessage(message:Object):void
		{
			for (var i:uint = 0; i < this.peerInfo.length; i ++)
				if (this.peerInfo[i].ip_address == message.ip_address)
				{
					this.peerInfo[i].country = message.country;
					this.peerInfo[i].delay = message.delay;
					this.peerInfo[i].total_time = message.total_time;
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
			obj.total_time = message.total_time;
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
			http_traffic = total_traffic = 0;
			for (var i:int = this.peerInfo.length-1; i >= 0; i --)		
				if ((this.time-this.peerInfo[i].timestamp) >= 600000)
				{
					this.peerInfo.splice(i, 1);
					for (var j:uint = 0; j < this.countryInfo.length; j ++)
						if (this.countryInfo[j]['text'] == this.peerInfo[i].country)
						{
							this.countryInfo[j]['value'] --;
							if (this.countryInfo[j]['value'] <= 0) this.countryInfo.splice(j, 1);
							break;
						}
				}
				else 
				{
					http_traffic += this.peerInfo[i].http_time;
					total_traffic += this.peerInfo[i].total_time;
				}
		}
		private function playlisterrorHandler(event:IOErrorEvent):void
		{
		}
		private function playlistloaderCompleteHandler(event:Event):void
		{
			var playlist:String = String(playlistloader.data);
			var index:int = playlist.indexOf("#EXTM3U");
			if (index != 0) return;
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
					index = playlist.indexOf("BANDWIDTH");
					var bandwidth:uint = 0;
					if (index != -1)	bandwidth = ReadNumber(playlist, index);
					// URI of the playlist within the variant playlist
					index = playlist.indexOf("http://", index);
					if (index == -1) break;
					end_index = playlist.indexOf(".m3u8", index);
					if (end_index == -1) break;
					AddQuality(playlist.substring(index, end_index+5), bandwidth);
					// next round
					index = playlist.indexOf("#EXT-X-STREAM-INF:");
				}
				if (qualities.length > 0)
				{
					current_quality = qualities[0];
					GetPlaylist(current_quality.playlisturls);
				}
				return;
			}
			// A normal playlist
			// default duration of the clip
			index = playlist.indexOf("#EXT-X-TARGETDURATION:");
			if (index != -1) end_index = ReadNumber(playlist, index);
			index = playlist.indexOf("#EXTINF:");
			// duration of the clip
			var time_length:uint = ReadNumber(playlist, index);
			// index of the clip
			index = playlist.indexOf("http://", index);
			if (index == -1) return;
			end_index = playlist.indexOf(".flv", index);
			if (end_index == -1) return;
			else end_index --;
			var clip_index:uint = 0;
			var i:uint = 0;
			// Read in the number in the reverse order, it should not be too big to exceed 32-bit value limit
			while ((playlist.charCodeAt(end_index) >= 48) && (playlist.charCodeAt(end_index) <= 57) && (i < 8))
			{
				clip_index = clip_index + (playlist.charCodeAt(end_index) - 48)*Math.pow(10, i);
				end_index --;	i ++;
			}
			if ((clip_index == 0) || (end_index <= index)) return;
			// URI of the clip
			if (current_quality.channel_name == null)
			{
				current_quality.channel_name = playlist.substring(index, end_index+1);
				JoinM3U8Group(current_quality);
			}
		}
		private function metadataGroupHandler(event:NetStatusEvent):void
		{
			switch(event.info.code)
			{
				case "NetGroup.Connect.Rejected":
				case "NetGroup.Connect.Failed":
					JoinM3U8Group(current_quality);
					break;
				case "NetGroup.Connect.Success":
				case "NetGroup.Neighbor.Connect":
					this.started = true;
					for (var i:uint = 0; i < qualities.length; i ++)
						if (qualities[i] == current_quality) break;
					if (qualities.length > (i+1))
					{
						current_quality = qualities[i+1];
						GetPlaylist(current_quality.playlisturls);
					}
					break;
				case "NetGroup.SendTo.Notify":
					// We assume all messages are destined to the server, so we directly process it
					ProcessMessage(event.info.message.value);
					break;
				default:
					break;
			}
		}		
	}
}
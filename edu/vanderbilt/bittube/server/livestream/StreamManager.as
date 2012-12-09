package edu.vanderbilt.bittube.server.livestream
{
	import flash.events.NetStatusEvent;
	import flash.events.TimerEvent;
	import flash.geom.Rectangle;
	import flash.media.Video;
	import flash.net.NetConnection;
	import flash.net.NetStream;
	import flash.utils.Timer;
	
	public class StreamManager
	{
		private const DEVELOPER_KEY:String = "c0c0a64365449434f59df7d4-1a7c848462c9";
		private var RTMFP_connected:Boolean; // status of RTMFP connection		
		private var streams_:Array; // Array of live streams (right now we only support one stream) 
		private var timer_:Timer; // timer to stream live video periodically, only ticking when there is at least one active stream
		private var timestamp_:uint; // current timestamp for the purpose of LineChart collection
		private var counter_:uint;
		public var bitrate_:LineChart; // bitrate of the live stream
		public var online_user_:LineChart; // # of online users
		public var server_load_:LineChart; // server load in terms of bytes/second
		public var peer_percentage_:LineChart; // peer contribution to the system in terms of percentage
		public var delay_:LineChart; // average delays experienced by peers
		public var http_time_:LineChart; // average delays experienced by peers
		public var num_interruptions_:LineChart; // average delays experienced by peers		
		public var symmetric_NAT_:LineChart; // average delays experienced by peers		
		public var user_location_:PieChart; // user location distribution
		public var live_nc:NetConnection; // NetConnection for connecting to RTMFP

		public function StreamManager(chart_width:uint, chart_height:uint):void
		{
			this.RTMFP_connected = false;
			this.live_nc = new NetConnection();
			this.live_nc.addEventListener(NetStatusEvent.NET_STATUS, netConnectionHandler);
			this.live_nc.connect("rtmfp://p2p.rtmfp.net/"+DEVELOPER_KEY);
			this.streams_ = new Array;
			// Start the timer
			this.timer_ = new Timer(1000);
			this.timer_.addEventListener(TimerEvent.TIMER, timerHandler)
			this.counter_ = 0;

			// Initialize LineCharts and PieChart
			this.timestamp_ = (uint)((new Date().getTime())/1000);
			this.bitrate_ = new LineChart("bitrate", new Rectangle(0, 0, chart_width, chart_height), this.timestamp_, 0);
			this.online_user_ = new LineChart("online users", new Rectangle(0, 0, chart_width, chart_height), this.timestamp_, 0);
			this.server_load_ = new LineChart("server load", new Rectangle(0, 0, chart_width, chart_height), this.timestamp_, 0);
			this.peer_percentage_ = new LineChart("peer percentage", new Rectangle(0, 0, chart_width, chart_height), this.timestamp_, 0);
			this.delay_ = new LineChart("average delay", new Rectangle(0, 0, chart_width, chart_height), this.timestamp_, 0);
			this.http_time_ = new LineChart("average startup delay", new Rectangle(0, 0, chart_width, chart_height), this.timestamp_, 0);
			this.num_interruptions_ = new LineChart("number of interruptions", new Rectangle(0, 0, chart_width, chart_height), this.timestamp_, 0);
			this.symmetric_NAT_ = new LineChart("percentage of symmetric NAT", new Rectangle(0, 0, chart_width, chart_height), this.timestamp_, 0);
			this.user_location_ = new PieChart("user locations", new Rectangle(0, 0, chart_width, chart_height), this.timestamp_, 1);
		}
		public function AddStream(stream:Stream, color:String=null):uint
		{
			this.bitrate_.AddElement(null, color);
			this.online_user_.AddElement(null, color);
			this.server_load_.AddElement(null, color);
			this.peer_percentage_.AddElement(null, color);
			this.delay_.AddElement(null, color);
			this.http_time_.AddElement(null, color);
			this.num_interruptions_.AddElement(null, color);
			this.symmetric_NAT_.AddElement(null, color);
			if (this.streams_.length == 0) this.timer_.start();
			this.streams_.push(stream);
			return (this.streams_.length-1);
		}
		public function RemoveStream(index:uint):Boolean
		{
			if (index >= this.streams_.length) return false;
			this.streams_.splice(index, 1);
			if (this.streams_.length == 0) this.timer_.stop();
			this.bitrate_.RemoveElement(index);
			this.online_user_.RemoveElement(index);
			this.server_load_.RemoveElement(index);
			this.peer_percentage_.RemoveElement(index);
			this.delay_.RemoveElement(index);
			this.http_time_.RemoveElement(index);
			this.num_interruptions_.RemoveElement(index);
			this.symmetric_NAT_.RemoveElement(index);
			return true;
		}		
		public function ChangeBackground(color:String):void
		{
			this.bitrate_.ChangeBackground(color);
			this.online_user_.ChangeBackground(color);
			this.server_load_.ChangeBackground(color);
			this.peer_percentage_.ChangeBackground(color);
			this.delay_.ChangeBackground(color);
			this.http_time_.ChangeBackground(color);
			this.num_interruptions_.ChangeBackground(color);
			this.symmetric_NAT_.ChangeBackground(color);
			this.user_location_.ChangeBackground(color);
		}
		public function IndexOf(channel:String):int
		{
			if (channel == null) return -1;
			for (var i:uint = 0; i < this.streams_.length; i ++)
				if (channel == this.streams_[i].channel_name)
					return i;
			return -1;
		}
		public function P2PReady():Boolean
		{
			return this.RTMFP_connected;
		}
		public function Start(urls:String, channelname:String, video:Video, index:uint):Stream
		{
			if (index >= this.streams_.length)
			{
				throw Error("Only supports "+this.streams_.length+" streams");
			}
			this.streams_[index].Start(urls, channelname, video);
			this.bitrate_.ChangeElementName(channelname, index);
			this.online_user_.ChangeElementName(channelname, index);
			this.server_load_.ChangeElementName(channelname, index);
			this.peer_percentage_.ChangeElementName(channelname, index);
			this.delay_.ChangeElementName(channelname, index);
			this.http_time_.ChangeElementName(channelname, index);
			this.num_interruptions_.ChangeElementName(channelname, index);
			this.symmetric_NAT_.ChangeElementName(channelname, index);
			return this.streams_[index]; 
		}
		public function Stop(index:uint):Boolean
		{
			if (index >= this.streams_.length) return false;
			return this.streams_[index].Stop();
		}
		private function timerHandler(event:TimerEvent):void
		{
			// If RTMFP server is not connected, it makes no sense to start reading the file
			if (RTMFP_connected == false)
			{
				live_nc.connect("rtmfp://p2p.rtmfp.net/"+DEVELOPER_KEY);
				return;
			}
			// Display LineChart every 5 seconds
			this.counter_ ++;
			if (this.counter_  == 60) // adjust timestamp every minute
			{
				this.counter_ = 0;
				this.timestamp_ = (uint)((new Date().getTime())/1000);
				for (i = 0; i < this.streams_.length; i ++)
					this.streams_[i].BroadcastID(live_nc.nearID);
			}
			var values:Array = new Array(this.streams_.length);
			for (var i:uint = 0; i < this.streams_.length; i ++)
				values[i] = this.streams_[i].CheckUpdate(this.timestamp_+this.counter_);			
			if (this.counter_ % 5 == 0)
			{
				this.bitrate_.NewValue(this.timestamp_+this.counter_, values);

				for (i = 0; i < this.streams_.length; i ++)
					if ((this.streams_[i].UserNumber() > 0) && (values[i] > 0))
						values[i] = Math.max(0, 1-this.streams_[i].DataBytesPerSecond()/(values[i]*this.streams_[i].UserNumber()));
					else values[i] = 0; 
				this.peer_percentage_.NewValue(this.timestamp_+this.counter_, values);

				for (i = 0; i < this.streams_.length; i ++)
					values[i] = this.streams_[i].UserNumber();
				this.online_user_.NewValue(this.timestamp_+this.counter_, values);

				for (i = 0; i < this.streams_.length; i ++)
					values[i] = this.streams_[i].DataBytesPerSecond();
				this.server_load_.NewValue(this.timestamp_+this.counter_, values);

				for (i = 0; i < this.streams_.length; i ++)
					values[i] = this.streams_[i].Delay();
				this.delay_.NewValue(this.timestamp_+this.counter_, values);
				
				for (i = 0; i < this.streams_.length; i ++)
					values[i] = this.streams_[i].HTTPTime();
				this.http_time_.NewValue(this.timestamp_+this.counter_, values);

				for (i = 0; i < this.streams_.length; i ++)
					values[i] = this.streams_[i].NumInterruptions();
				this.num_interruptions_.NewValue(this.timestamp_+this.counter_, values);
				
				for (i = 0; i < this.streams_.length; i ++)
					if (this.streams_[i].UserNumber() > 0)
						values[i] = Number(this.streams_[i].symmetricNAT()/this.streams_[i].UserNumber());
				this.symmetric_NAT_.NewValue(this.timestamp_+this.counter_, values);

				for (i = 0; i < this.streams_.length; i ++)
					values[i] = this.streams_[i].UserLocations();
				this.user_location_.NewValue(this.timestamp_+this.counter_, values);
			}
		}
		private function netConnectionHandler(event:NetStatusEvent):void
		{
			switch (event.info.code)
			{
				case "NetConnection.Connect.Success":
					RTMFP_connected = true;
					for (var i:uint = 0; i < this.streams_.length; i ++)
					{
						this.streams_[i].JoinMetadataGroup();
						this.streams_[i].JoinNetGroup();
					}
					break;
				case "NetConnection.Connect.Closed":
				case "NetConnection.Connect.Failed":
					RTMFP_connected = false;
					break;
			}
		}		
	}	
}
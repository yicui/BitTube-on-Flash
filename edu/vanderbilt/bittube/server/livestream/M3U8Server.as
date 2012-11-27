package edu.vanderbilt.bittube.server.livestream
{
	import flash.display.MovieClip;
	import flash.external.ExternalInterface;
	
	import openflashchart.MainChart;
	
	public class M3U8Server extends MovieClip 
	{
		private var manager_:StreamManager;

		public function M3U8Server():void
		{
			manager_ = new StreamManager(320, 240);

			addChild(manager_.online_user_.chart);			manager_.online_user_.chart.x = 0;			manager_.online_user_.chart.y = 0;
			addChild(manager_.server_load_.chart);			manager_.server_load_.chart.x = 325;		manager_.server_load_.chart.y = 0;
			addChild(manager_.bitrate_.chart);				manager_.bitrate_.chart.x = 650;			manager_.bitrate_.chart.y = 0;
			addChild(manager_.peer_percentage_.chart);		manager_.peer_percentage_.chart.x = 0;		manager_.peer_percentage_.chart.y = 245;
			addChild(manager_.num_interruptions_.chart);	manager_.num_interruptions_.chart.x = 325;	manager_.num_interruptions_.chart.y = 245;
			addChild(manager_.http_time_.chart);			manager_.http_time_.chart.x = 650;			manager_.http_time_.chart.y = 245;
			addChild(manager_.delay_.chart);				manager_.delay_.chart.x = 0;				manager_.delay_.chart.y = 490;
			addChild(manager_.symmetric_NAT_.chart);		manager_.symmetric_NAT_.chart.x = 325;		manager_.symmetric_NAT_.chart.y = 490;
			addChild(manager_.user_location_.chart);		manager_.user_location_.chart.x = 650;		manager_.user_location_.chart.y = 490;
			if (ExternalInterface.available)
			{
				ExternalInterface.addCallback("AddStream", AddStream);
				ExternalInterface.addCallback("RemoveStream", RemoveStream);
				ExternalInterface.addCallback("ChangeBackground", ChangeBackground);
			}
		}
		public function AddStream(urls:String, channel:String, color:String):void
		{
			try
			{
				if (manager_.IndexOf(channel) != -1) throw Error("Channel "+channel+" already exists");
				var index:uint = manager_.AddStream(new M3U8Stream(manager_), color);
				manager_.Start(urls, channel, null, index);
			}
			catch (error:Error)
			{
				if (ExternalInterface.available) ExternalInterface.call("ShowMsg", error.toString());
			}
		}		
		public function RemoveStream(channel:String):void
		{
			try
			{
				var index:int = manager_.IndexOf(channel);				
				if (index < 0) throw Error("Cannot find channel "+channel);;
				manager_.Stop(index);
				manager_.RemoveStream(index);
			}
			catch (error:Error)
			{
				if (ExternalInterface.available) ExternalInterface.call("ShowMsg", error.toString());
			}			
		}
		public function ChangeBackground(color:String):void
		{
			manager_.ChangeBackground(color);
		}		
	}
}

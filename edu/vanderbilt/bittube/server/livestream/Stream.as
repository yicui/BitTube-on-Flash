package edu.vanderbilt.bittube.server.livestream
{
	import flash.media.Video;
	
	public class Stream
	{
		public var channel_name:String; // name of the channel
		public var video:Video; // video
		public function Start(urls:String, channelname:String, video:Video):void {}
		public function Stop():Boolean {return false;}
		public function CheckUpdate(input_time:uint):uint {return 0;}
		public function BroadcastID(ID:String):void {}
		public function DataBytesPerSecond():uint {return 0;}
		public function UserNumber():uint {return 0;}
		public function Delay():uint {return 0;}
		public function HTTPTime():uint {return 0;}
		public function NumInterruptions():Number {return 0;}
		public function symmetricNAT():uint {return 0;}
		public function UserLocations():Array {return null;}
		public function JoinMetadataGroup():void {}
		public function JoinNetGroup():void {}
	}
}
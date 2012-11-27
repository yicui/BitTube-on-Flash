package edu.vanderbilt.bittube.player 
{
	import flash.events.*;
	import flash.net.*;
	
	public class LocationMonitor
	{
		private var nat_nc:NetConnection; // NetConnection to test NAT		
		private var loader:URLLoader; // loader to fetch URL data
		private var results:Object;
		
		public function LocationMonitor()
		{
			results = new Object();
			results.symmetric_NAT = results.ip_address = results.country = null;
			// Test NAT connectivity
			nat_nc = new NetConnection();
			nat_nc.addEventListener(NetStatusEvent.NET_STATUS, natHandler);
			nat_nc.connect("rtmfp://216.104.221.8");	
			
			// Try to learn its own IP address
			try 
			{
				loader = new URLLoader(new URLRequest("http://ip-address.domaintools.com/myip.xml"));
			}
			catch (error:Error)
			{
				
			}						
			loader.addEventListener(IOErrorEvent.IO_ERROR, errorHandler);
			loader.addEventListener(Event.COMPLETE, loaderCompleteHandler);
		}
		public function Results():Object
		{
			return results;
		}
		private function natHandler(event:NetStatusEvent) : void
		{
			if (event.info.code == "NetConnection.ConnectivityCheck.Results")
			{
				if (event.info.sendAfterIntroductionAllowed)
					if (event.info.sendAfterIntroductionPreservesSourcePort) 
						results.symmetric_NAT = false;
					else results.symmetric_NAT = true;
			}
			return;
		}
		private function errorHandler(event:IOErrorEvent):void
		{
		}
		private function loaderCompleteHandler(event:Event):void
		{
			var result:XML = new XML(loader.data);
			results.ip_address = result.ip_address.toString();
			results.country = result.country.toString();
		}		
	}
}
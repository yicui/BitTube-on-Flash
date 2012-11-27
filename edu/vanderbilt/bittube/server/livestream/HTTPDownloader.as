package edu.vanderbilt.bittube.server.livestream
{
	import flash.events.Event;
	import flash.events.IOErrorEvent;
	import flash.events.ProgressEvent;
	import flash.events.SecurityErrorEvent;
	import flash.net.Socket;
	import flash.system.Security;
	import flash.utils.ByteArray;
	
	public class HTTPDownloader
	{
		public var server_:String; // Server Address
		private var port_:uint; // Server Port
		private var url_:String; // URL
		public var sock_:Socket;

		public function HTTPDownloader(url:String)
		{
			// If player does not have a name, return -1
			if (url == null) return;
			// read server address
			var start_pos:int = url.search("http://");
			if (start_pos == -1) start_pos = 0;
			else start_pos += 7;
			var end_pos:uint = start_pos;
			while ((end_pos < url.length) && (url.charCodeAt(end_pos) != 47) && (url.charCodeAt(end_pos) != 58)) 
				end_pos ++;
			if (end_pos == url.length) return;
			this.server_ = url.slice(start_pos, end_pos);
			// read port number if any
			this.port_ = 0;
			if (url.charCodeAt(end_pos) == 58)
			{
				end_pos ++;
				while ((end_pos < url.length) && (url.charCodeAt(end_pos) >= 48) && (url.charCodeAt(end_pos) <= 57))
				{
					this.port_ = this.port_ * 10 + url.charCodeAt(end_pos)-48;
					end_pos ++;
				}					
			}
			else this.port_ = 80;
			if ((end_pos == url.length) || (url.charCodeAt(end_pos) != 47)) return;
			// read URL
			this.url_ = url.substr(end_pos);
			//Security.loadPolicyFile("xmlsocket://"+this.server_+":843");
			this.sock_ = new Socket(this.server_, this.port_);
			this.sock_.addEventListener(Event.CONNECT, connectionHandler);
			this.sock_.addEventListener(IOErrorEvent.IO_ERROR, ioErrorHandler);
			this.sock_.addEventListener(SecurityErrorEvent.SECURITY_ERROR, securityErrorHandler); 
		}
		public function GetData():void  
		{
			// If downloading is in progress or the length is 0 byte, simply return false
			if (this.sock_.connected == false)
			{
				// This is to combat the socket connection delay problem: Do not use the socket until the connect event arrives  				
				this.sock_.connect(server_, port_);
				return;
			}
			var s:String = "GET "+this.url_+" HTTP/1.1\r\nHost:localhost\r\nConnection: Keep-Alive\r\n\r\n";
			this.sock_.writeMultiByte(s, "us-ascii");
			this.sock_.flush();
		}
		public function ReadHTTPResponse(input:ByteArray):uint
		{
			// Check HTTP Header
			var s:String = input.toString();
			var position:int = s.search("HTTP");
			if (position >= 1)
				throw new Error("HTTPDownloader::ReadHTTPResponse: Wrong HTTP Header");
			// Check response Code
			input.position = 0;
			while ((input.bytesAvailable) && (String.fromCharCode(input.readByte()) != " ") && (String.fromCharCode(input.readByte()) != "\n"))
			{}
			var response:uint = 0;
			while (input.bytesAvailable)
			{
				var code:uint = input.readByte();
				if ((code >= 48) && (code <= 57))
					response = response * 10 + code-48;
				else break;
			} 
			if ((response != 200) && (response != 206))
				throw new Error("HTTPDownloader::ReadHTTPResponse: Wrong Response Code"+response);

			// Find out the starting point of the payload
			position = s.search("\r\n\r\n");
			if (position == -1)
				throw new Error("HTTPDownloader::ReadHTTPResponse: Fail to find payload");
			return position + 4;
		}
		private function connectionHandler(event:Event):void
		{
			GetData();
		} 
		private function ioErrorHandler(event:Event):void
		{
			this.sock_.close();
		} 
		private function securityErrorHandler(event:Event):void
		{
			if (this.sock_.connected == true) this.sock_.close();
			//Security.loadPolicyFile("xmlsocket://"+this.server_+":843");
			this.sock_ = new Socket(this.server_, this.port_);
			this.sock_.addEventListener(Event.CONNECT, connectionHandler);
			this.sock_.addEventListener(IOErrorEvent.IO_ERROR, ioErrorHandler);
			this.sock_.addEventListener(SecurityErrorEvent.SECURITY_ERROR, securityErrorHandler); 
		}
	}
}
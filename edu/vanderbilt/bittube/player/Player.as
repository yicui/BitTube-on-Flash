package edu.vanderbilt.bittube.player 
{
	import flash.display.DisplayObject;
	import flash.display.MovieClip;
	import flash.display.StageDisplayState;
	import flash.events.*;
	import flash.geom.Rectangle;
	import flash.media.SoundTransform;
	import flash.media.Video;
	import flash.net.*;
	import flash.system.Security;
	import flash.text.TextField;
	import flash.utils.Timer;

	public class Player extends MovieClip 
	{
		private const DEVELOPER_KEY:String = "c0c0a64365449434f59df7d4-1a7c848462c9";
		private const update_interval:uint = 60;		
		// Network related objects	
		private var RTMFP_connected:Boolean; // status of RTMFP connection
		private var live_nc:NetConnection; // NetConnection for connecting to RTMFP
		private var ns:NetStream; // NetStream for playback	
		// Scheduler and the timer to run it 
		private var scheduler:Scheduler;
		private var timer:Timer; 
		private var counter:uint; // time counter
		// UI components
		private var video:Video;
		private var _fullScreenBtn:MovieClip;
		private var _bufferLoading:MovieClip;
		private var _fullScreenMsg:TextField;
		private var _playBtn:MovieClip;
		private var _pauseBtn:MovieClip;
		private var _soundBtn:MovieClip;
		private var _muteBtn:MovieClip;
		private var _volumeBar:MovieClip;
		private var _volumeKnob:MovieClip;

		public function Player():void 
		{
			try 
			{
				Security.allowDomain("*");
				counter = 0;
				// first loading
				var _firstLoading = new cycle1_stage();
				_firstLoading.name = "firstLoading";
				_firstLoading.x=stage.stageWidth/2;
				_firstLoading.y=stage.stageHeight/2;
				addChild(_firstLoading);
				// fullscreen button
				_fullScreenBtn  = new fullscreenBtn();
				_fullScreenBtn.x = stage.stageWidth - 145;
				_fullScreenBtn.y = stage.stageHeight - _fullScreenBtn.height -5;
				_fullScreenBtn.buttonMode = true;
				_fullScreenBtn.addEventListener(MouseEvent.CLICK, onFullScreenBtnClick);
				_fullScreenBtn.addEventListener(MouseEvent.ROLL_OVER, onFullScreenBtnRollOver);
				_fullScreenBtn.addEventListener(MouseEvent.ROLL_OUT, onFullScreenBtnRollOut);
				_fullScreenBtn.addEventListener(MouseEvent.MOUSE_OVER, onFullScreenBtnRollOver);
				stage.addEventListener(FullScreenEvent.FULL_SCREEN, stageHandler);
				// play button
				_playBtn  = new playBtn();
				_playBtn.x = 20;
				_playBtn.y = stage.stageHeight - _playBtn.height -5;
				_playBtn.buttonMode = true;
				_playBtn.addEventListener(MouseEvent.CLICK, onPlayBtnClick);
				// pause button
				_pauseBtn  = new pauseBtn();
				_pauseBtn.x = 20;
				_pauseBtn.y = stage.stageHeight - _pauseBtn.height -5;
				_pauseBtn.buttonMode = true;
				_pauseBtn.addEventListener(MouseEvent.CLICK, onPauseBtnClick);
				// buffer loading 	
				_bufferLoading = new bufferLoading();
				_bufferLoading.name = "bufferLoading";
				_bufferLoading.x=_playBtn.x+55;
				_bufferLoading.y=stage.stageHeight-_bufferLoading.height+5;
				// sound button
				_soundBtn  = new soundBtn();
				_soundBtn.x = _fullScreenBtn.x + 35;
				_soundBtn.y = stage.stageHeight - _soundBtn.height -5;
				_soundBtn.buttonMode = true;
				_soundBtn.addEventListener(MouseEvent.CLICK, onSoundBtnClick);
				// mute button
				_muteBtn  = new muteBtn();
				_muteBtn.x = _soundBtn.x + 5;
				_muteBtn.y = stage.stageHeight - _soundBtn.height -5;
				_muteBtn.buttonMode = true;
				_muteBtn.addEventListener(MouseEvent.CLICK, onMuteBtnClick);
				// volume bar
				_volumeBar = new vlmBar();
				_volumeBar.x = _soundBtn.x + _soundBtn.width + 5;
				_volumeBar.y = _soundBtn.y + _soundBtn.height/2 - _volumeBar.height/2;
				_volumeBar.buttonMode = true;
				_volumeBar.addEventListener(MouseEvent.CLICK, onSetVolume);
				// volume bar
				_volumeKnob = new vlmKnob();
				_volumeKnob.x = _volumeBar.x + _volumeBar.width/2 - _volumeKnob.width/2;
				_volumeKnob.y = _volumeBar.y + _volumeBar.height/2 - _volumeKnob.height/2;
				_volumeKnob.buttonMode = true;				
				_volumeKnob.addEventListener(MouseEvent.MOUSE_DOWN, onVolumeKnobDrag);
				_volumeKnob.addEventListener(MouseEvent.MOUSE_UP, onVolumeKnobReleased);
				_volumeKnob.addEventListener(MouseEvent.MOUSE_OUT, onVolumeKnobReleased);	
				// Screen message							
				_fullScreenMsg	= new TextField();
				_fullScreenMsg.width = 80;
				_fullScreenMsg.height = 25;
				_fullScreenMsg.background = true;
				_fullScreenMsg.backgroundColor = 0xF5F5DC;
				_fullScreenMsg.border = true;
				_fullScreenMsg.x = stage.stageWidth - _fullScreenBtn.width - _fullScreenMsg.width - 10;
				_fullScreenMsg.y = stage.stageHeight - _fullScreenBtn.height -10;
				_fullScreenMsg.visible = false;

				// Read input parameters
				var parameters:Object = new Object();
				parameters.urls = loaderInfo.parameters['urls'];
				parameters.channel_name = loaderInfo.parameters['name'];
				parameters.patience_interval = uint(loaderInfo.parameters['patience']);
				if (parameters.patience_interval == 0) 
					parameters.patience_interval = 3;
				parameters.playback_time = uint(loaderInfo.parameters['playback']);	
				if (parameters.playback_time == 0) 
					parameters.playback_time = 600;

				// Get prepared to start netGroup
				RTMFP_connected = false;
				live_nc = new NetConnection();
				live_nc.addEventListener(NetStatusEvent.NET_STATUS, netConnectionHandler);
				live_nc.connect("rtmfp://p2p.rtmfp.net/"+DEVELOPER_KEY);
				// Set the video aspect ratio to 4:3
				if ((stage.stageHeight - _fullScreenBtn.height -43)/stage.stageWidth < 0.75)
					video = new Video((stage.stageHeight - _fullScreenBtn.height -43)*4/3, stage.stageHeight - _fullScreenBtn.height -43);
				else video = new Video(stage.stageWidth, stage.stageWidth*3/4);
				video.x = (stage.stageWidth-video.width)/2; video.y = 29;
				video.smoothing = true;
				addChild(video);
				// Start local video playback
				var nsClient:Object = {};
				nsClient.onMetaData = ns_onMetaData;
				nsClient.onCuePoint = ns_onCuePoint;
				var nc:NetConnection = new NetConnection();
				nc.connect(null);
				ns = new NetStream(nc);
				ns.client = nsClient;
				ns.addEventListener(NetStatusEvent.NET_STATUS, localStreamHandler);
				video.attachNetStream(ns);
				ns.play(null);

				// Instantiate different scheduler based on the input URL
				if (parameters.urls.match(".m3u8") != null)
					scheduler = new M3U8Scheduler(live_nc, ns, parameters);
				else scheduler = new HTTPScheduler(live_nc, ns, parameters);
				
				// Start timer
				timer = new Timer(1000);
				timer.addEventListener(TimerEvent.TIMER, timerHandler)
				timer.start();
				
				if (String(loaderInfo.parameters['fullscreen']) == 'true')
					stage.displayState = StageDisplayState.FULL_SCREEN;
				else
				{
					stage.displayState = StageDisplayState.NORMAL;
					addChild(_fullScreenBtn);
				}				
				addChild(_pauseBtn);
				addChild(_soundBtn);	
				addChild(_volumeBar);
				addChild(_volumeKnob);
				addChild(_fullScreenMsg);
				//SetVol((_volumeKnob.x - _volumeBar.x) / _volumeBar.width);
			}
			catch (error:Error)
			{
			}
		}
		public function Pause():void
		{
			ns.pause();
			timer.stop();
		}
		public function Resume():void
		{
			ns.resume();
			timer.start();
		}		
		private function ns_onMetaData(item:Object):void 
		{
		}
		private function ns_onCuePoint(item:Object):void 
		{
		}
		private function timerHandler(event:TimerEvent):void 
		{
			// If RTMFP server is not connected, it makes no sense to start reading the file
			if (RTMFP_connected == false)
			{
				live_nc.connect("rtmfp://p2p.rtmfp.net/"+DEVELOPER_KEY);
				return;
			}
			scheduler.Update();
			counter ++;
			if (counter % update_interval == 0)
				scheduler.ReportStatistics();			
		}
		private function onPlayBtnClick(e:MouseEvent):void
		{
			Resume();
			removeChild(_playBtn);	addChild(_pauseBtn);
		}
		private function onPauseBtnClick(e:MouseEvent):void
		{
			Pause();
			removeChild(_pauseBtn);	addChild(_playBtn);
		}
		private function onSoundBtnClick(e:MouseEvent):void
		{
			SetVol(0);
			addChild(_muteBtn);			
		}
		private function onMuteBtnClick(e:MouseEvent):void
		{
			SetVol((_volumeKnob.x - _volumeBar.x) / _volumeBar.width);
			removeChild(_muteBtn);
		}
		private function SetVol(v:Number):void
		{
			var transform:SoundTransform = new SoundTransform(v);
			ns.soundTransform = transform;
		}
		private function onSetVolume(e:MouseEvent):void
		{
			_volumeKnob.x = e.stageX - _volumeKnob.width/2;
			SetVol((_volumeKnob.x - _volumeBar.x) / _volumeBar.width);
		}
		private function onVolumeKnobDrag(e:MouseEvent):void
		{
			_volumeKnob.startDrag(false, new Rectangle(_volumeBar.x-_volumeKnob.width/2, _volumeKnob.y, _volumeBar.width, 0));
		}
		private function onVolumeKnobReleased(e:MouseEvent):void
		{
			_volumeKnob.stopDrag();
			SetVol((_volumeKnob.x - _volumeBar.x) / _volumeBar.width);
		}
		private function onFullScreenBtnClick(e:MouseEvent):void
		{
			if (stage.displayState == StageDisplayState.NORMAL)	
			{
				//var screenRectangle:Rectangle = new Rectangle(0, 0, 200, 200);
				//stage.fullScreenSourceRect = screenRectangle;			
				stage.displayState = StageDisplayState.FULL_SCREEN;
			}
			else 
				stage.displayState = StageDisplayState.NORMAL;
		}
		private function onFullScreenBtnRollOver(e:MouseEvent):void
		{
			_fullScreenMsg.text = "Full Screen";
			_fullScreenMsg.visible = true;
		}
		private function onFullScreenBtnRollOut(e:MouseEvent):void
		{
			_fullScreenMsg.text = "";
			_fullScreenMsg.visible = false;
		}
		private function stageHandler(event:FullScreenEvent):void
		{
			if(event.fullScreen == true) removeChild(_fullScreenBtn);
			else addChild(_fullScreenBtn);
		}
		private function netConnectionHandler(event:NetStatusEvent):void
		{
			switch (event.info.code)
			{
				case "NetConnection.Connect.Success":
					RTMFP_connected = true;
					break;
				case "NetConnection.Connect.Closed":
				case "NetConnection.Connect.Failed":
					RTMFP_connected = false;
					if (timer.running == false) 
						timer.start();					
					break;
				default:
					break;
			}
		}
		private function localStreamHandler(event:NetStatusEvent):void
		{
			var firstLoading:DisplayObject;
			switch(event.info.code)
			{	
				case "NetStream.Buffer.Full":
					firstLoading = getChildByName("firstLoading");
					if (firstLoading != null) removeChild(firstLoading);
					firstLoading = getChildByName("bufferLoading");
					if (firstLoading != null) removeChild(firstLoading);
					break;
				case "NetStream.Buffer.Empty":
					// sometimes empty event comes many times, we just remember the first one					
					scheduler.Jam();					
					if ((getChildByName("firstLoading") == null) && (getChildByName("bufferLoading") == null))
						addChild(_bufferLoading);
					break;
			}
		}		
	}
}
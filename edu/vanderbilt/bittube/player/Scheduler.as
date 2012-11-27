package edu.vanderbilt.bittube.player
{
	public interface Scheduler
	{
		// Called periodically by the player to drive downloading of the video
		function PeriodicUpdate():void;
		// This is to notify the scheduler when the video stops playing due to buffer empty  
		function Jam():void;
		// Called to report downloading statistics to the server
		function ReportStatistics():void;		
	}
package edu.vanderbilt.bittube.server.livestream
{	
	import flash.geom.Rectangle;
	import openflashchart.MainChart;
	
	public class Chart
	{
		protected var json:Object;
		public var chart:MainChart;

		public function Chart(title:String, stage:Rectangle, input_json:Object)
		{
			if (input_json == null)	this.json = new Object;
			else this.json = input_json;
			
			this.json['title'] = new Object;
			this.json['title']['text'] = title;
			this.json['title']['style'] = new Object;
			this.json['title']['style']['font-size'] = '20px';
			this.json['title']['style']['margin-top'] = 0;
			this.json['title']['style']['margin-bottom'] = 0;
			this.json['title']['style']['padding-top'] = 0;
			this.json['title']['style']['padding-bottom'] = 0;
			
			this.json['tooltip'] = new Object;
			this.json['tooltip']['shadow'] = false;
			this.json['tooltip']['stroke'] = 2;
			this.json['tooltip']['mouse'] = 0;
			this.json['tooltip']['colour'] = '#00d000';
			this.json['tooltip']['background'] = '#d0d0ff';
			this.json['tooltip']['title'] = new Object;
			this.json['tooltip']['title']['font-size'] = '14px'; 
			this.json['tooltip']['title']['color'] = '#905050';
			this.json['tooltip']['body'] = new Object;
			this.json['tooltip']['body']['font-size'] = '10px';
			this.json['tooltip']['body']['font-weight'] = 'bold';
			this.json['tooltip']['body']['color'] = '#9090ff';
			this.json['tooltip']['text'] = 'title<br>body';
			
			this.chart = new MainChart(this.json, stage);
		}
		public function ChangeElementName(name:String, index:uint):Boolean
		{
			if ((name == null) || (this.json['elements'].length <= index)) return false;
			this.json['elements'][index]['text'] = name;
			this.chart.build_chart(this.json);
			return true;
		}
		public function ChangeElementColor(color:String, index:uint):Boolean
		{
			if ((color == null) || (color == "") || (this.json['elements'].length <= index)) return false;
			this.json['elements'][index]['colour'] = color;
			this.chart.build_chart(this.json);
			return true;			
		}
		public function ChangeBackground(color:String):Boolean
		{
			if ((color == null) || (color == "")) return false;
			this.json.bg_colour = color;
			this.chart.build_chart(this.json);
			return true;			
		}
		public function NewValue(timestamp:uint, values:Array):void
		{
		}
	}
}
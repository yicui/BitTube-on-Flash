package edu.vanderbilt.bittube.server.livestream
{	
	import flash.geom.Rectangle;
	import openflashchart.MainChart;
	
	public class LineChart extends Chart
	{
		public function LineChart(title:String, stage:Rectangle, timestamp:uint, num_of_streams:uint)
		{
			var localjson:Object = new Object;
			localjson['x_axis'] = new Object;
			localjson['x_axis']['max'] = timestamp;
			localjson['x_axis']['min'] = localjson['x_axis']['max']-60;
			localjson['x_axis']['steps'] = 5; // 5 seconds interval
			localjson['x_axis']['labels'] = new Object;
			localjson['x_axis']['labels']['rotate'] = 345;
			localjson['x_axis']['labels']['steps'] = 5;
			localjson['x_axis']['labels']['visible-steps'] = 2;
			localjson['x_axis']['labels']['text'] = '#date:l jS, M Y#';
			
			localjson['y_axis'] = new Object;
			localjson['y_axis']['min'] = 0;
			localjson['y_axis']['max'] = 1;
			localjson['y_axis']['stroke'] = 2;
			localjson['y_axis']['steps'] = 1;
			localjson['y_axis']['offset'] = 0;
			
			localjson['elements'] = new Array();
			super(title, stage, localjson);
			for (var count:uint = 0; count < num_of_streams; count ++)
				AddElement(null, null);
		}
		public function AddElement(name:String, color:String):void
		{
			var element:Object = new Object();
			element['type'] = 'scatter_line';
			if ((color != null) && (color != ""))
				element['colour'] = color;
			else
			switch (this.json['elements'].length)
			{
				case 0:
					element['colour'] = '#1f3cd0';
					break;
				case 1:
					element['colour'] = '#d01f3c';
					break;
				case 2:
					element['colour'] = '#6BBA70';
					break;
				case 3:
					element['colour'] = '#0000FF';
					break;
				case 4:
					element['colour'] = '#FF0000';
					break;
				case 5:
					element['colour'] = '#00FF00';
					break;
				case 6:
					element['colour'] = '#BB2cd0';
					break;
				case 7:
					element['colour'] = '#00BB3c';
					break;
				case 8:
					element['colour'] = '#0000AA';
					break;
				case 9:
					element['colour'] = '#EE2cc0';
					break;
				case 10:
					element['colour'] = '#d1EE3c';
					break;
				case 11:
					element['colour'] = '#4B3AEE';
					break;
				default: break;
			}
			element['alpha'] = 0.6;
			element['border'] = 2;
			element['animate'] = 0;
			element['dot-style'] = new Object();
			element['dot-style']['tip'] = '#date:d M y#<br>#y#\n(left axis)';
			element['dot-style']['type'] = 'solid-dot';
			element['width'] = 4;
			if ((name == null) || (name == ""))
				element['text'] = 'Stream # '+this.json['elements'].length;
			else element['text'] = name; 
			
			element['values'] = new Array();
			for (var i:uint = this.json['x_axis']['min']; i <= this.json['x_axis']['max']; i += this.json['x_axis']['steps'])
			{
				var value:Object = new Object();
				value['x'] = i;	value['y'] = 0;	
				element['values'].push(value);
			}
			this.json['elements'].push(element);
			this.chart.build_chart(this.json);
		}
		public function RemoveElement(index:uint):void
		{
			if (this.json['elements'].length <= index) return;
			this.json['elements'].splice(index, 1);
			this.chart.build_chart(this.json);			
		}		
		public override function NewValue(timestamp:uint, values:Array):void
		{
			this.json['y_axis']['max'] = 1;
			for (var i:uint = 0; i < this.json['elements'].length; i ++)
			{
				this.json['elements'][i]['values'].shift();
				var value:Object = new Object();
				value['x'] = timestamp;	
				// In case an empty values array is input, just fill with 0
				if (i < values.length) value['y'] = values[i];
				else value['y'] = 0;				
				this.json['elements'][i]['values'].push(value);
				
				for (var j:uint = 0; j < this.json['elements'][i]['values'].length; j ++) 
					if (this.json['elements'][i]['values'][j]['y'] > this.json['y_axis']['max']) 
						this.json['y_axis']['max'] = this.json['elements'][i]['values'][j]['y']; 
			}
			// We assume the new value's timestamp is always bigger than the previous one
			this.json['x_axis']['min'] = this.json['elements'][0]['values'][0]['x'];
			this.json['x_axis']['max'] = timestamp;
			
			this.chart.build_chart(this.json);
		}
	}
}
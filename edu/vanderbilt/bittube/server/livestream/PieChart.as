package edu.vanderbilt.bittube.server.livestream
{	
	import flash.geom.Rectangle;
	import openflashchart.MainChart;
	
	public class PieChart extends Chart
	{
		public function PieChart(title:String, stage:Rectangle, timestamp:uint, num_of_streams:uint)
		{
			var json:Object = new Object;
			
			json['elements'] = new Array();
			
			for (var count:uint = 0; count < num_of_streams; count ++)
			{
				var element:Object = new Object();
				element['type'] = 'pie';
				element['start-angle'] = 180; 
				element['colours'] = new Array();
				element['colours'].push('#d01f3c','#356aa0','#C79810','#73880A','#D15600','#6BBA70');
				element['alpha'] = 0.6;
				element['border'] = 2;
				element['animate'] = 0;
				element['text'] = 'Stream # '+count;
				
				element['values'] = null;
				json['elements'].push(element);

				super(title, stage, json);
			}
		}
		public override function NewValue(timestamp:uint, values:Array):void
		{	
			for (var i:uint = 0; i < this.json['elements'].length; i ++)
			{
				// If the values array is out of scope or empty, create a dump one-element array just to draw the pie 
				if ((i >= values.length) || (values[i] == null) || (values[i].length == 0))
				{
					var value:Object = new Object();
					value['text'] = 'Empty';	value['value'] = 1;
					this.json['elements'][i]['values'] = new Array;
					this.json['elements'][i]['values'].push(value);			
				}
				else 
				{
					this.json['elements'][i]['values'] = values[i];
					//Alert.show("pie "+this.json['elements'][i]['values'][0]['text']+" "+this.json['elements'][i]['values'][0]['value']);
				}
			}
			this.chart.build_chart(this.json);
		}
	}
}
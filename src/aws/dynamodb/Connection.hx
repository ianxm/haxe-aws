/****
* Copyright (C) 2013 Sam MacPherson
* 
* Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
* 
* The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
* 
* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
****/

package aws.dynamodb;

import aws.auth.IAMConfig;
import aws.auth.Sig4Http;
import aws.dynamodb.DynamoDBError;
import aws.dynamodb.DynamoDBException;
import haxe.crypto.Base64;
import haxe.io.Bytes;
import haxe.io.BytesOutput;
import haxe.io.Input;
import haxe.io.Output;
import haxe.Json;

#if !js
private class PersistantSocket {
	
	public var input(default, null):Input;
	public var output(default, null):Output;
	public var s(default, null):Dynamic;
	
	public function new (s:Dynamic) {
		this.s = s;
		this.input = s.input;
		this.output = s.output;
	}
	
	public function actualConnect (host:sys.net.Host, port:Int):Void {
		s.connect(host, port);
	}
	
	public function actualClose ():Void {
		s.close();
		s = null;
	}
	
	public function connect (host:sys.net.Host, port:Int):Void {
		//Do nothing
	}
	
	public function setTimeout (t:Float):Void {
		s.setTimeout(t);
	}
	
	public function write (str:String):Void {
		s.write(str);
	}
	
	public function close ():Void {
		//Do nothing
	}
	
	public function shutdown (read:Bool, write:Bool):Void {
		//Do nothing
	}
	
}
#end

/**
 * Controls all database interaction.
 * 
 * @author Sam MacPherson
 */

class Connection {
	
	static inline var SERVICE:String = "DynamoDB";
	static inline var API_VERSION:String = "20120810";
	
	var config:DynamoDBConfig;
	#if !js var sock:PersistantSocket; #end
	var connected:Bool;
	
	/**
	 * Create a new DynamoDB connection.
	 * 
	 * @param config An IAM configuration file.
	 */
	public function new (config:DynamoDBConfig) {
		this.config = config;
		connected = false;
	}
	
	/**
	 * Initiate the connection.
	 */
	public function connect ():Void {
		connected = true;
		#if !js
		if (config.ssl) sock = new PersistantSocket(new sys.ssl.Socket());
		else sock = new PersistantSocket(new sys.net.Socket());
		
		var hostPort = config.host.split(":");
		var host;
		var port;
		if (hostPort.length >= 2) {
			host = hostPort[0];
			port = Std.parseInt(hostPort[1]);
		} else {
			host = hostPort[0];
			port = config.ssl ? 443 : 80;
		}
		sock.actualConnect(new sys.net.Host(host), port);
		#end
	}
	
	/**
	 * Close the connection.
	 */
	public function close ():Void {
		connected = false;
		#if !js
		sock.actualClose();
		#end
	}
	
	function formatError (httpCode:Int, type:String, message:String, payload:String):Void {
		var type = type.substr(type.indexOf("#") + 1);
		var message = message;
		
		if (httpCode == 413) throw RequestTooLarge;
		for (i in Type.getEnumConstructs(DynamoDBError)) {
			if (type == i) {
				if (type == "ValidationException") throw ValidationException(message);
				else if (type == "ConditionalCheckFailedException") throw ConditionalCheckFailedException(payload);
				else throw Type.createEnum(DynamoDBError, i);
			}
		}
		for (i in Type.getEnumConstructs(DynamoDBException)) {
			if (type == i) throw Type.createEnum(DynamoDBException, i);
		}
		
		throw "Error: " + type + "\nMessage: " + message + "\nPayload: " + payload;
	}
	
	function _sendRequest (operation:String, payload:Dynamic): #if js js.Promise<Dynamic> #else Dynamic #end {
		var conn = new Sig4Http((config.ssl ? "https" : "http") + "://" + config.host + "/", config);
		conn.setHeader("content-type", "application/x-amz-json-1.0; charset=utf-8");
		conn.setHeader("x-amz-target", SERVICE + "_" + API_VERSION + "." + operation);
		conn.setHeader("Connection", "Keep-Alive");
		var payloadStr = Json.stringify(payload);
		conn.setPostData(payloadStr);
		
		#if js
		return new js.Promise(function (resolve, reject) {
			conn.onData = function (_data:String) {
				resolve(Json.parse(_data));
			};
			conn.onError = function (err:String) {
				try {
					var out = Json.parse(conn.responseData);
					try {
						formatError(Std.parseInt(err.substr(err.indexOf("#") + 1)), out.__type, out.message, payloadStr);
					} catch (e:Dynamic) {
						reject(e);
					}
				} catch (e:Dynamic) {
					reject(ConnectionInterrupted);
				}
			};
			conn.applySigning(true);
			conn.request(true);
		});
		#else
		var err = null;
		conn.onError = function (msg:String):Void {
			err = msg;
		}
		
		var data:BytesOutput = new BytesOutput();
		conn.applySigning(true);
		conn.customRequest(true, data, sock);
		var out:Dynamic;
		try {
			out = Json.parse(data.getBytes().toString());
		} catch (e:Dynamic) {
			throw ConnectionInterrupted;
		}
		if (err != null) formatError(Std.parseInt(err.substr(err.indexOf("#") + 1)), out.__type, out.message, payloadStr);
		return out;
		#end
	}
	
	public function sendRequest (operation:String, payload:Dynamic): #if js js.Promise<Dynamic> #else Dynamic #end {
		if (!connected) connect();
		
		#if js
		var delay = 0;
		function doReq ():js.Promise<Dynamic> {
			return _sendRequest(operation, payload).then(function (res:Dynamic) {
				return res;
			}).catchError(function (e:Dynamic) {
				if (Std.is(e, DynamoDBException)) {
					return new js.Promise(function (resolve, reject) {
						haxe.Timer.delay(function () {
							doReq().then(function (res:Dynamic) {
								resolve(res);
							}).catchError(function (e:Dynamic) {
								reject(e);
							});
						}, (1 << delay) * 1000);
						delay++;
					});
				} else {
					return js.Promise.reject(e);
				}
			});
		}
		return doReq();
		#else
		var res = null;
		var delay = 0;
		while (true) {
			try {
				res = _sendRequest(operation, payload);
			} catch (e:Dynamic) {
				if (!Std.is(e, DynamoDBException)) {
					throw e;
				}
				Sys.sleep(1 << delay);
				delay++;
			}
		}
		return res;
		#end
	}
	
}
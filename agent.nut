// MIT License

// Copyright 2019 Electric Imp

// SPDX-License-Identifier: MIT

// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:

// The above copyright notice and this permission notice shall be
// included in all copies or substantial portions of the Software.

// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO
// EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES
// OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
// ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
// OTHER DEALINGS IN THE SOFTWARE.

#require "Messenger.lib.nut:0.1.0"

// CLOUD SERVICES   
// --------------------------------------------------------------
// Manages Cloud Service Communications  

// Dependencies: AzureIoTHub
// Initializes: AzureIoTHub
class Cloud {
    
    devConnStr = null;
    client     = null;
    _deviceID  = null;
    
    constructor() {
        _deviceID = imp.configparams.deviceid;
        // Stores this devices connection string in class variable
        _getDeviceConnString();

        if (devConnStr != null) { 
            client = AzureIoTHub.Client(devConnStr, _onConnected.bindenv(this), _onDisconnected.bindenv(this));
            client.connect();
        } else {
            server.error("[Cloud] No Azure IoT Hub credentials for this device. Connection to Azure IoT Hub NOT established");
        }
    }
    
    function send(report) {
        if (devConnStr == null) return;
        // TODO: 
        // Format report data if more that json encoding the report table is needed
        // Check cloud connection state, and resend if not connected 
        local msg = AzureIoTHub.Message(http.jsonencode(data));
        client.sendMessage(msg, _onMsgSent.bindenv(this));
    }
    
        function _onMsgSent(err, msg) {
        if (err != 0) {
            server.error("[Cloud] IotHub send message failed: " + err);
            // TODO: Implement retry sending
            return;
        }
        server.log("[Cloud] IoTHub message sent");
    }

    function _onConnected(err) {
        if (err != 0) {
            server.error("[Cloud] IotHub connect failed: " + err);
            return;
        }
        server.log("[Cloud] IoTHub connected");
    }

    function _onDisconnected(err) {
        if (err != 0) {
            server.error("[Cloud] IoTHub disconnected unexpectedly with code: " + err);
            
            // Reconnect if disconnection is not initiated by application
            client.connect();
        } else {
            server.log("[Cloud] IoTHub disconnected by application");
        }
    }

    function _getDeviceConnString() {
        return null;
        // Use hardcoded values stored in imp.config file to get 
        // IoTHub Device Connection string for this device
        switch(_deviceID) {
            case "@{DEV_1_ID}": // Betsy's test device
                devConnStr = "@{DEV_1_IOTHUB_DEV_CONN_STR}";
                break;
            case "@{DEV_2_ID}": // Custom IBC board
                devConnStr = "@{DEV_2_IOTHUB_DEV_CONN_STR}";
                break;
            case "@{DEV_3_ID}": // Breakout board (1)
                devConnStr = "@{DEV_3_IOTHUB_DEV_CONN_STR}";
                break;
            case "@{DEV_4_ID}": // Breakout board (2)
                devConnStr = "@{DEV_4_IOTHUB_DEV_CONN_STR}";
                break;
        }
    }
}


// MAIN APPLICATION   
// --------------------------------------------------------------
// Configures and Runs the Main Application  

// Max time to wait for agent/device message ack
const MSG_ACK_TIMEOUT = 10;
// Messenger reporting message name 
const MSGR_REPORT     = "report"; 

// Dependencies: Cloud
// Initializes: Cloud
class Main {
    
    cloud = null;
    msgr  = null;
    
    constructor() {
        server.log("--------------------------------------------------------------------------");
        server.log("Agent started...");
        server.log("--------------------------------------------------------------------------");
        
        msgr = Messenger({"ackTimeout" : MSG_ACK_TIMEOUT});
        msgr.on(MSGR_REPORT, onReport.bindenv(this));
        
        cloud = Cloud();
    }

    function onReport(payload, custAck) {
        local report = payload.data;
        
        server.log("[Main] Report from device received: ");
        server.log(http.jsonencode(report));
        
        cloud.send(report);
    }
}


// RUNTIME
// -----------------------------------------------------------------------

// Start application
Main();

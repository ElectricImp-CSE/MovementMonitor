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

// Include Libraries
#require "LIS3DH.device.lib.nut:2.0.3"
#require "MAX17055.device.lib.nut:1.0.1"
#require "BQ25895.device.lib.nut:3.0.0"
#require "Messenger.lib.nut:0.1.0"
#require "ConnectionManager.lib.nut:3.1.1"


// HAL   
// --------------------------------------------------------------
// Hardware Abstraction Layer
// Values for impC001-ibc-tracker rev1.0

// NOTE: For application to work properly only values should be 
// updated, names must remain the same
LED_RED         <- hardware.pinM;
LED_GREEN       <- hardware.pinYT;
LED_BLUE        <- hardware.pinYJ;

GPS_UART        <- hardware.uartNU;
PWR_GATE_EN     <- hardware.pinYB;

BATT_CHGR_INT   <- hardware.pinL;

// Sensor i2c AKA i2c0 in schematics
SENSOR_I2C      <- hardware.i2cXDC;     
ACCEL_INT       <- hardware.pinW;      
TEMP_HUMID_ADDR <- 0xBE;
ACCEL_ADDR      <- 0x32;
BATT_CHGR_ADDR  <- 0xD4;
FUEL_GAUGE_ADDR <- 0x6C;   

// Recommended for offline logging, remove when in production    
LOGGING_UART    <- hardware.uartDCAB;


// BATTERY   
// --------------------------------------------------------------
// Battery Monitoring File
// NOTE: This class is currently written for a rechargable LiCoO2 battery.
// Confirm settings before using.

// Settings for a 3.7V 2000mAh battery from Adafruit and impC001 breakout
const BATT_CHARGE_VOLTAGE = 4.2;
const BATT_CURR_LIMIT     = 2000;
const FG_DES_CAP          = 2000;   // mAh
const FG_SENSE_RES        = 0.01;   // ohms
const FG_CHARGE_TERM      = 20;     // mA
const FG_EMPTY_V_TARGET   = 3.3;    // V
const FG_RECOVERY_V       = 3.88;   // V
// NOTE: Fuel gauge setting chrgV, battType are set using library constant,
// please check these settings if updating these constants.

const BATT_STATUS_CHECK_TIMEOUT = 0.5;

// Manages Battery Monitoring
// Dependencies: MAX17055, BQ25895 (may configure sensor i2c) Libraries
// Initializes: MAX17055, BQ25895 Libraries
class Battery {

    charger = null;
    fg      = null;

    fgReady = null;

    constructor(configureI2C) {
        if (configureI2C) SENSOR_I2C.configure(CLOCK_SPEED_400_KHZ);

        charger = BQ25895(SENSOR_I2C, BATT_CHGR_ADDR);
        fg = MAX17055(SENSOR_I2C, FUEL_GAUGE_ADDR);

        // Configure charger
        charger.enable({"voltage": BATT_CHARGE_VOLTAGE, "current": BATT_CURR_LIMIT});

        local fgSettings = {
            "desCap"       : FG_DES_CAP,
            "senseRes"     : FG_SENSE_RES,
            "chrgTerm"     : FG_CHARGE_TERM,
            "emptyVTarget" : FG_EMPTY_V_TARGET,
            "recoveryV"    : FG_RECOVERY_V,
            "chrgV"        : MAX17055_V_CHRG_4_2,
            "battType"     : MAX17055_BATT_TYPE.LiCoO2
        }
        // NOTE: Full init will only run when "power on reset alert is detected",
        // so call this here so ready flag is always set.
        fg.init(fgSettings, function(err) {
            if (err != null) {
                ::error("[Battery] Error initializing fuel gauge: " + err);
            } else {
                fgReady = true;
            }
        }.bindenv(this));
    }

    function getStatus(cb = null) {
        if (fgReady) {
            if (cb == null) return fg.getStateOfCharge();
            cb(fg.getStateOfCharge());
        } else if (cb != null) {
            imp.wakeup(BATT_STATUS_CHECK_TIMEOUT, function() {
                getStatus(cb);
            }.bindenv(this))
        }
    }

    function checkStatus(thresh, cb) {
        getStatus(function(soc) {
            local status = soc;
            status.battAlert <- (soc.percent <= thresh) ? ALERT_DESC.LOW : ALERT_DESC.IN_RANGE;
            status.ts        <- time();
            cb(status);
        }.bindenv(this))
    }
}

// MOTION   
// --------------------------------------------------------------
// Configures and Manages Accelerometer and Motion Sensing 

// Number of readings per sec
const ACCEL_DATA_RATE     = 100;
// Number of readings condition must be true before int triggered 
const ACCEL_INT_DURATION  = 10; 
// Duration between accel readings when sampling
const ACCEL_CHECK_SEC     = 0.05;

// Dependencies: LIS3DH library
// Initializes: LIS3DH
class Motion {

    accel       = null;
    sampleTimer = null;
    
    constructor() {
        SENSOR_I2C.configure(CLOCK_SPEED_400_KHZ);
        accel = LIS3DH(SENSOR_I2C, ACCEL_ADDR);
    }
    
    function enableAccel() {
        accel.setDataRate(ACCEL_DATA_RATE);
        accel.setMode(LIS3DH_MODE_LOW_POWER);
        accel.enable(true);
    }
    
    function disableAccel() {
        accel.setDataRate(0);
        accel.enable(false);
    }
    
    function startAccelSampling(onReading) {
        accel.getAccel(onReading);
        _cancelSamplingTimer();
        sampleTimer = imp.wakeup(ACCEL_CHECK_SEC, function() {
            startAccelSampling(onReading);
        }.bindenv(this));
    }
    
    function stopAccelSampling() {
        _cancelSamplingTimer();
    }
    
    function enableInt(threshold, onInterrupt = null) {
        server.log("[Motion] Enabling motion detection");
        
        // Configures and enables motion interrupt
        accel.reset();
        enableAccel();
        accel.configureHighPassFilter(LIS3DH_HPF_AOI_INT1, LIS3DH_HPF_CUTOFF1, LIS3DH_HPF_NORMAL_MODE);
        accel.getInterruptTable();
        accel.configureInertialInterrupt(true, threshold, ACCEL_INT_DURATION, LIS3DH_X_HIGH | LIS3DH_Y_HIGH | LIS3DH_Z_HIGH);
        accel.configureInterruptLatching(false);
        
        configIntIntPin(onInterrupt);
    }
    
    // This method does NOT clear the latched interrupt pin. It disables the accelerometer and reconfigures wake pin.  
    function disableInt() {
        server.log("[Motion] Disabling motion detection");

        // Disables accelerometer 
        disableAccel();

        // Disable accel interrupt and high pass filter
        accel.configureHighPassFilter(LIS3DH_HPF_DISABLED);
        accel.configureInertialInterrupt(false);

        // Note: Configuring pin doesn't chage pin's current state
        // Reconfiguring int pin 
            // Disables wake on pin high
            // Clear state change callback
        ACCEL_INT.configure(DIGITAL_IN_PULLDOWN); 
    }
    
    function configIntIntPin(onInterrupt = null) {
        // Configure interrupt pin 
            // Wake when interrupt occurs 
            // (optional) With state change callback to catch interrupts when awake
        if (onInterrupt != null) {
            ACCEL_INT.configure(DIGITAL_IN_WAKEUP, onInterrupt);
        } else {
            ACCEL_INT.configure(DIGITAL_IN_WAKEUP);
        }
    }
    
    // Returns boolean if interrupt was detected. 
    // Note: Calling this method clears the interrupt.
    function detected() {
        server.log("[Motion] Checking and clearing interrupt");
        // Get interrupt table. Note this clears the interrupt data 
        local res = accel.getInterruptTable();
        // Return boolean - if motion event has occurred
        return res.int1;
    }
    
    function _cancelSamplingTimer() {
        if (sampleTimer != null) {
            imp.cancelwakeup(sampleTimer);
            sampleTimer = null;
        }
    }
    
    // Helper returns bool if accel is enabled
    function _isAccelEnabled() {
        // bits 0-2 xyz enabled, 3 low-power enabled, 4-7 data rate
        local val = accel._getReg(LIS3DH_CTRL_REG1);
        return (val & 0x07) ? true : false;
    }

    // Helper returns bool if accel inertial interrupt is enabled
    function _isAccelIntEnabled() {
        // bit 7 inertial interrupt is enabled,
        local val = accel._getReg(LIS3DH_CTRL_REG3);
        return (val & 0x40) ? true : false;
    }    
}


// MONITOR   
// --------------------------------------------------------------
// Main application, motion event monitoring

// G-force that will trigger a movement event/accelerometer sampling
const MOVEMENT_THRESHOLD       = 1.0;
// Time in seconds to monitor accelometer data after a movement event
const MOVEMENT_SAMPLE_TIME_SEC = 60; 
// Number of readings to keep in sliding window
const READING_WINDOW_SIZE      = 10; 
// During movement event report accel data every x seconds
const EVENT_REPORTING_INT_SEC  = 1;

// Max time to wait for agent/device message ack
const MSG_ACK_TIMEOUT          = 10;
// Retry message send after x seconds
const MSG_RETRY_TIMEOUT        = 1.5;
// Messenger reporting message names 
const MSGR_REPORT              = "report"; 
const MSGR_BATT_STATUS         = "batt"; 

// Dependencies: Motion class
// Initializes: Motion
class Monitor {
    
    move               = null;
    msgr               = null;
    cm                 = null;
    batt               = null;
    
    accelWindow        = null;
    stopSamplingTmr    = null;
    reportTimer        = null;
    monitoringMovement = null;
    
    constructor() {
        cm = ConnectionManager({ "blinkupBehavior" : CM_BLINK_ALWAYS,
                                 "stayConnected"   : true,
                                 "retryOnTimeout"  : true });
        imp.setsendbuffersize(8096);
        
        server.log("--------------------------------------------------------------------------");
        server.log("Device started...");
        server.log(imp.getsoftwareversion());
        server.log("--------------------------------------------------------------------------");
        
        // Configure application defaults
        monitoringMovement = false;
        accelWindow = array(READING_WINDOW_SIZE, null);
        
        // Initialize Messenger for agent/device communication 
        // Defaults: message ackTimeout set to 10s, max num msgs 10, default msg ids
        msgr = Messenger({"ackTimeout" : MSG_ACK_TIMEOUT});
        msgr.onFail(msgrOnFail.bindenv(this));
        msgr.onAck(msgrOnAck.bindenv(this));
        
        // Initialized motion event detection
        move = Motion();
        move.enableInt(MOVEMENT_THRESHOLD, onMovement.bindenv(this));
        
        batt = Battery(false);
        monitorBattery();
    }
    
    // Msgr handlers
    // -------------------------------------------------------------

    // Global Message Failure handler
    function msgrOnFail(msg, reason) {
        // Store message info in variables
        local payload = msg.payload;
        local id      = payload.id;
        local name    = payload.name;
        local msgData = payload.data;

        server.error(format("[Monitor] %s message send failed: %s", name, reason));

        // Handle each type of message failure
        switch(name) {
            case MSGR_REPORT:
                // Drop message if we are not connected or message timeed out,
                // otherwise retry after a timeout 
                if (reason == MSGR_ERR_RATE_LIMIT_EXCEEDED) {
                    imp.wakeup(MSG_RETRY_TIMEOUT, function() {
                        resendMsg(name, msgData);
                    }.bindenv(this))
                }
                break;
            default: 
                server.log("[Monitor] Unrecognized message send failed: " + name);
        }
    }

    function msgrOnAck(msg, ackData) {
        // Store message info in variables
        local payload = msg.payload;
        local id      = payload.id;
        local name    = payload.name;
        local msgData = payload.data;
        
        return;

        // Handle each type of message failure
        switch(name) {
            case MSGR_REPORT:
                server.log(format("[Monitor] %i message send ACK-ed: %s", id, name));
                break;
            default: 
                server.log("[Monitor] Unrecognized message send ACK-ed: " + name);
        }
    }
    
    function resendMsg(name, data) {
        if (server.isconnected()) {
            // If first message fails retry
            server.log(format("Monitor] Retrying %s message send.", name));
            // Retry message 
            msgr.send(name, data);
        }
    }
    
    // Asyc Action Handlers
    // -------------------------------------------------------------
    
    function onMovement() {
        // Only take action if pin is pulled high
        if (ACCEL_INT.read() == 0 || monitoringMovement) return;
        
        server.log("--------------------------------------------");
        server.log("[Monitor] Movement above threshold detected.");
        server.log("--------------------------------------------");
        
        startMonitoringFor(MOVEMENT_SAMPLE_TIME_SEC);
    }
    
    function onAccelReading(r) {
        accelWindow.append(r);
        accelWindow.remove(0);
    }
    
    // Monitoring Functions
    // -------------------------------------------------------------
    
    function startMonitoringFor(monTime = MOVEMENT_SAMPLE_TIME_SEC) {
        // Toggle movemnt monitoring flag
        monitoringMovement = true;
        
        // Cancel all timers that are currently running
        _cancelStopSamplingTimer();
        _cancelReportTimer();
        
        // Start sampling, on each new sample passes accel reading to 
        // onAccelReading handler
        server.log("[Monitor] Start sampling accelerometer");
        move.startAccelSampling(onAccelReading.bindenv(this));
        
        // Schedule when to stop sampling
        stopSamplingTmr = imp.wakeup(monTime, stopSampling.bindenv(this));
        
        // Start reporting average accel readings
        server.log("[Monitor] Start reporting accel data");
        reportTimer = imp.wakeup(EVENT_REPORTING_INT_SEC, sendReport.bindenv(this));
    }
    
    function stopSampling() {
        server.log("-----------------------------------------------");
        server.log("[Monitor] Stopping accel sampling and reporting");
        server.log("-----------------------------------------------");
        move.stopAccelSampling();
        _cancelReportTimer();
        // Reset accelWindow
        accelWindow = array(READING_WINDOW_SIZE, null);
        
        // NOTE: Can delay toggling this flag to optimize battery consumption if movement
        // events are too close together
        // Reset Movement Monitoring flag
        monitoringMovement = false;
    }
    
    function sendReport() {
        // Create report
        local report = getAvgAccel();
        report.ts <- time();
        
        // Send to agent
        server.log("[Monitor] Sending report to agent");
        msgr.send(MSGR_REPORT, report);
        
        // Schedule next report
        reportTimer = imp.wakeup(EVENT_REPORTING_INT_SEC, sendReport.bindenv(this));
    }
    
    function getAvgAccel() {
        local ctr = 0;
        
        local avgX = 0;
        local avgY = 0;
        local avgZ = 0;
        
        // Get totals for each reading
        foreach(r in accelWindow) {
            if (r == null || !("x" in r && "y" in r && "z" in r)) continue;
            ctr++;
            avgX += r.x;
            avgY += r.y;
            avgZ += r.z;
        }
        
        // Return null if we didn't have any valid readings
        if (ctr == 0) return null;
        
        // Calculate average
        avgX /= ctr;
        avgY /= ctr;
        avgZ /= ctr;
        
        return {
            "mag" : math.sqrt(avgX*avgX + avgY*avgY + avgZ*avgZ),
            "x"   : avgX,
            "y"   : avgY,
            "z"   : avgZ
        };
    }
    
    function monitorBattery() {
        batt.getStatus(function(soc) {
            soc.ts <- time();
            msgr.send(MSGR_BATT_STATUS, soc);
            imp.wakeup(600, monitorBattery.bindenv(this));
        }.bindenv(this));
    }
    
    // Timer Helpers
    // -------------------------------------------------------------   
    
    function _cancelStopSamplingTimer() {
        if (stopSamplingTmr != null) {
            imp.cancelwakeup(stopSamplingTmr);
            stopSamplingTmr = null;
        }
    }
    
    function _cancelReportTimer() {
        if (reportTimer != null) {
            imp.cancelwakeup(reportTimer);
            reportTimer = null;
        }
    }
    
}


// RUNTIME
// -----------------------------------------------------------------------

// Start application
Monitor();


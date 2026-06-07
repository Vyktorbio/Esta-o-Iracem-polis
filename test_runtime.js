var fs = require('fs');
var path = require('path');
var jsdom = require('jsdom');
var JSDOM = jsdom.JSDOM;

var htmlPath = '/Users/victorchavesmachado/Documents/projeto bioestat/index.html';
var html = fs.readFileSync(htmlPath, 'utf8');
var vendorDir = '/Users/victorchavesmachado/Documents/projeto bioestat/vendor';

var virtualConsole = new jsdom.VirtualConsole();
virtualConsole.on("error", function(err) {
  console.error("CONSOLE ERROR:", err);
});
virtualConsole.on("jsdomError", function(err) {
  console.error("JSDOM error:", err.message);
  if (err.stack) console.error(err.stack);
});
virtualConsole.on("log", function(msg) {
  console.log("Console log:", msg);
});

// Set up JSDOM window without loading external network resources (prevent JSDOM network errors)
var dom = new JSDOM(html, {
  runScripts: "outside-only",
  virtualConsole: virtualConsole
});

var window = dom.window;

// Mock APIs that are not implemented in JSDOM or fail
Object.defineProperty(window, 'alert', {
  value: function(msg) { console.log("MOCKED ALERT:", msg); },
  writable: true,
  configurable: true
});
var store = {};
Object.defineProperty(window, 'localStorage', {
  value: {
    getItem: function(key) { return store[key] || null; },
    setItem: function(key, val) { store[key] = String(val); },
    removeItem: function(key) { delete store[key]; },
    clear: function() { store = {}; }
  },
  writable: true,
  configurable: true
});
window.navigator.geolocation = {
  watchPosition: function() {},
  getCurrentPosition: function() {}
};
window.onerror = function(msg, url, line, col, err) {
  console.error("WINDOW RUNTIME ERROR:", msg, "at line", line, "col", col);
  if (err) console.error(err.stack);
};

// Helper to execute a JS file inside the JSDOM context
function executeFile(filePath) {
  var code = fs.readFileSync(filePath, 'utf8');
  try {
    dom.window.eval(code);
  } catch (e) {
    console.error("Error executing " + path.basename(filePath) + ":", e.message);
    if (e.stack) console.error(e.stack);
  }
}

// 1. Load vendor libraries in order
executeFile(path.join(vendorDir, 'leaflet.js'));
// Mock LF
window.LF = window.L;

executeFile(path.join(vendorDir, 'leaflet-rotate.js'));
executeFile(path.join(vendorDir, 'Leaflet.ImageOverlay.Rotated.js'));
executeFile(path.join(vendorDir, 'quadras-default.js'));
executeFile(path.join(vendorDir, 'supabase.js'));

// 2. Extract and run inline script blocks from index.html
var scriptRegex = /<script\b[^>]*>([\s\S]*?)<\/script>/gi;
var match;
var count = 0;

while ((match = scriptRegex.exec(html)) !== null) {
  var openingTag = match[0].substring(0, match[0].indexOf('>') + 1);
  var srcMatch = openingTag.match(/src=["'](.*?)["']/i);
  if (srcMatch) {
    // Skip external script files as they are loaded manually above
    continue;
  }
  var code = match[1];
  count++;
  console.log("Running inline script " + count + "...");
  try {
    dom.window.eval(code);
  } catch (e) {
    console.error("Runtime error in script " + count + ":", e.message);
    if (e.stack) console.error(e.stack);
    process.exit(1);
  }
}

console.log("JSDOM execution completed. Checking for errors in window.onload...");
try {
  // Trigger DOMContentLoaded and onload events
  var event = window.document.createEvent("Event");
  event.initEvent("DOMContentLoaded", true, true);
  window.document.dispatchEvent(event);
  
  var loadEvent = window.document.createEvent("Event");
  loadEvent.initEvent("load", true, true);
  window.dispatchEvent(loadEvent);
} catch (e) {
  console.error("Error during load/init trigger:", e.message);
  if (e.stack) console.error(e.stack);
  process.exit(1);
}

// Unit tests for Admin Control and BPL Audit trail mapping
try {
  console.log("Running Admin Control Unit Tests...");
  dom.window.eval(`
    (function() {
      data = {}; // Initialize data object for testing
      ensureConfig();
      if (!data.__config) throw new Error("ensureConfig did not initialize __config");
      if (data.__config.adminPassword !== 'admin123') throw new Error("default password incorrect");

      // First email checked should become the adminEmail if empty
      var isAllowed = checkAccess('admin@agracta.com');
      if (!isAllowed) throw new Error("First access should set adminEmail and be allowed");
      if (data.__config.adminEmail !== 'admin@agracta.com') throw new Error("adminEmail not set on first checkAccess");

      // Another email should not be allowed (unauthorized technician)
      var isAllowed2 = checkAccess('tech@agracta.com');
      if (isAllowed2) throw new Error("Non-authorized technician should not have access");

      // Authorize technician
      data.__config.allowedUsers.push({ email: 'tech@agracta.com', nome: 'John Doe' });
      var isAllowed3 = checkAccess('tech@agracta.com');
      if (!isAllowed3) throw new Error("Authorized technician should have access");

      // Check audit log user friendly name resolution
      _authUser = { email: 'tech@agracta.com' };
      var study = { audit: [] };
      logStudyAuditInObject(study, 'Test Action', 'Test Details');
      if (study.audit[0].user !== 'John Doe') throw new Error("Audit log should resolve tech friendly name. Found: " + study.audit[0].user);
    })()
  `);
  console.log("Admin Control Unit Tests PASSED successfully.");
} catch (e) {
  console.error("Unit test failed:", e.message);
  process.exit(1);
}


// Wait a bit and exit
setTimeout(function() {
  console.log("Check complete.");
  process.exit(0);
}, 500);


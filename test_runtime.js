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

// Unit tests for Admin Control, BPL Audit trail, Input validation, and Role-based Merge
try {
  console.log("Running Comprehensive Application Audit Tests...");
  dom.window.eval(`
    (function() {
      // 1. Config initialization and basic access checks
      data = {};
      ensureConfig();
      if (!data.__config) throw new Error("ensureConfig did not initialize __config");
      if (data.__config.adminPassword !== '21ecaab54a2b091391b1fb10eaf969fabbee7cdad3724f3371ae4dc72b4dad0f') throw new Error("default password hash incorrect");
      if (data.__config.adminEmail !== 'machadovictorchaves@gmail.com') throw new Error("default admin email incorrect");

      var isAllowed = checkAccess('machadovictorchaves@gmail.com');
      if (!isAllowed) throw new Error("Admin email should be allowed");

      var isAllowed2 = checkAccess('tech@agracta.com');
      if (isAllowed2) throw new Error("Non-authorized technician should not have access");

      data.__config.allowedUsers.push({ email: 'tech@agracta.com', nome: 'John Doe' });
      var isAllowed3 = checkAccess('tech@agracta.com');
      if (!isAllowed3) throw new Error("Authorized technician should have access");

      // 2. Audit log friendly name resolution
      _authUser = { email: 'tech@agracta.com' };
      var study = { audit: [] };
      logStudyAuditInObject(study, 'Test Action', 'Test Details');
      if (study.audit[0].user !== 'John Doe') throw new Error("Audit log should resolve tech friendly name");

      _authUser = { email: 'machadovictorchaves@gmail.com' };
      var studyAdmin = { audit: [] };
      logStudyAuditInObject(studyAdmin, 'Admin Action', 'Admin Details');
      if (studyAdmin.audit[0].user !== 'Administrador') throw new Error("Audit log should resolve admin name");

      _authUser = null;
      var studyOffline = { audit: [] };
      logStudyAuditInObject(studyOffline, 'Offline Action', 'Offline Details');
      if (studyOffline.audit[0].user !== 'Local/Offline') throw new Error("Audit log should resolve offline name");

      // 3. Range and input validation (avValidateCell)
      _avGrid = { tipos: { v1: 'pct', v2: 'contagem' } };
      
      // Test percentage validation (max 100, min 0)
      var inpPctOver = { getAttribute: function() { return 'v1'; }, value: '150' };
      avValidateCell(inpPctOver);
      if (inpPctOver.value !== '100') throw new Error("Percentage > 100 should be coerced to 100");

      var inpPctUnder = { getAttribute: function() { return 'v1'; }, value: '-10' };
      avValidateCell(inpPctUnder);
      if (inpPctUnder.value !== '0') throw new Error("Percentage < 0 should be coerced to 0");

      // Test count validation (negative coerced to 0, decimals floored)
      var inpCountNeg = { getAttribute: function() { return 'v2'; }, value: '-5' };
      avValidateCell(inpCountNeg);
      if (inpCountNeg.value !== '0') throw new Error("Negative count should be coerced to 0");

      var inpCountDec = { getAttribute: function() { return 'v2'; }, value: '12.8' };
      avValidateCell(inpCountDec);
      if (inpCountDec.value !== '12') throw new Error("Count decimal should be floored");

      var inpInvalid = { getAttribute: function() { return 'v2'; }, value: 'abc' };
      avValidateCell(inpInvalid);
      if (inpInvalid.value !== '') throw new Error("Invalid number input should be reset to empty");

      // 4. Secure local storage cache clearing
      localStorage.setItem('iracema-v7', '{"test":"data"}');
      localStorage.setItem('iracema-safety', '[]');
      clearLocalStorageData();
      if (localStorage.getItem('iracema-v7') !== null) throw new Error("clearLocalStorageData did not clear iracema-v7");
      if (localStorage.getItem('iracema-safety') !== null) throw new Error("clearLocalStorageData did not clear iracema-safety");

      // 5. Config merge logic role priority (admin vs tech)
      var localConf = {
        data: {
          __config: { adminEmail: 'machadovictorchaves@gmail.com', adminPassword: 'old', allowedUsers: [] }
        }
      };
      var cloudConf = {
        data: {
          __config: { adminEmail: 'machadovictorchaves@gmail.com', adminPassword: 'new', allowedUsers: [{ email: 't1@agracta.com', nome: 'Tech 1' }] }
        }
      };

      // When admin merges, local wins
      _authUser = { email: 'machadovictorchaves@gmail.com' };
      var mergedAdmin = cloudMerge(localConf, cloudConf);
      if (mergedAdmin.data.__config.adminPassword !== 'old') throw new Error("Admin local config should overwrite cloud config");

      // When technician merges, cloud wins
      _authUser = { email: 't1@agracta.com' };
      var mergedTech = cloudMerge(localConf, cloudConf);
      if (mergedTech.data.__config.adminPassword !== 'new') throw new Error("Tech local config should be overwritten by cloud config");
    })()
  `);
  console.log("Comprehensive Application Audit Tests PASSED successfully.");
} catch (e) {
  console.error("Audit test failed:", e.message);
  process.exit(1);
}


// Wait a bit and exit
setTimeout(function() {
  console.log("Check complete.");
  process.exit(0);
}, 500);


(function () {
  "use strict";

  var config = window.__RUSTDESK_CONFIG__ || {};
  var values = {
    "custom-rendezvous-server": config.rendezvousServer,
    "rendezvous-server": config.rendezvousServer,
    "relay-server": config.relayServer,
    "api-server": config.apiServer,
    "key": config.publicKey
  };

  Object.keys(values).forEach(function (key) {
    var value = values[key];
    if (typeof value === "string" && value.length > 0) {
      window.localStorage.setItem(key, value);
    }
  });
})();

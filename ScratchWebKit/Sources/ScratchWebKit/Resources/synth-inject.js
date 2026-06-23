//
// synth-inject.js
//
// Replaces window.speechSynthesis / SpeechSynthesisUtterance with a shim that
// bridges to the native AVSpeechSynthesizer (see WebSpeechSynth.swift), so that
// the Web Speech `pitch` (character voices) works inside the WKWebView.
// Injected at document start.
//
(function () {
    "use strict";

    if (!window.webkit ||
        !window.webkit.messageHandlers ||
        !window.webkit.messageHandlers.synthSpeak) {
        return; // native bridge is not available
    }

    var post = function (name, body) {
        try {
            window.webkit.messageHandlers[name].postMessage(body);
        } catch (e) {
            // ignore
        }
    };

    // Shadow a (possibly read-only) window property with our own value.
    var setWindowProp = function (name, value) {
        try {
            Object.defineProperty(window, name, {value: value, configurable: true, writable: true});
        } catch (e) {
            try { window[name] = value; } catch (e2) { /* ignore */ }
        }
    };

    var instances = new Map();
    var nextId = 1;

    function ScrubUtterance(text) {
        this.text = (text === undefined) ? "" : String(text);
        this.lang = "";
        this.pitch = 1;
        this.rate = 1;
        this.volume = 1;
        this.voice = null;
        this.onstart = null;
        this.onend = null;
        this.onerror = null;
        this._listeners = {};
        this._id = 0;
    }
    ScrubUtterance.prototype.addEventListener = function (type, fn) {
        (this._listeners[type] = this._listeners[type] || []).push(fn);
    };
    ScrubUtterance.prototype.removeEventListener = function (type, fn) {
        var a = this._listeners[type];
        if (!a) { return; }
        var i = a.indexOf(fn);
        if (i >= 0) { a.splice(i, 1); }
    };
    ScrubUtterance.prototype._emit = function (type) {
        var event = {type: type, target: this};
        var handler = this["on" + type];
        if (typeof handler === "function") {
            try { handler.call(this, event); } catch (e) { /* ignore */ }
        }
        var a = this._listeners[type];
        if (a) {
            a.slice().forEach(function (fn) {
                try { fn.call(this, event); } catch (e) { /* ignore */ }
            }, this);
        }
    };

    var speechSynthesisShim = {
        speaking: false,
        pending: false,
        paused: false,
        speak: function (utterance) {
            if (!utterance) { return; }
            utterance._id = nextId++;
            instances.set(utterance._id, utterance);
            this.speaking = true;
            post("synthSpeak", {
                id: utterance._id,
                text: utterance.text || "",
                lang: utterance.lang || "",
                pitch: (typeof utterance.pitch === "number") ? utterance.pitch : 1,
                rate: (typeof utterance.rate === "number") ? utterance.rate : 1
            });
        },
        cancel: function () {
            this.speaking = false;
            post("synthCancel", {});
        },
        pause: function () {},
        resume: function () {},
        getVoices: function () { return []; },
        addEventListener: function () {},
        removeEventListener: function () {}
    };

    var coordinator = {
        receiveStart: function (id) {
            var u = instances.get(id);
            if (u) { u._emit("start"); }
        },
        receiveEnd: function (id) {
            var u = instances.get(id);
            if (!u) { return; }
            instances.delete(id);
            if (instances.size === 0) { speechSynthesisShim.speaking = false; }
            u._emit("end");
        },
        receiveError: function (id) {
            var u = instances.get(id);
            if (!u) { return; }
            instances.delete(id);
            if (instances.size === 0) { speechSynthesisShim.speaking = false; }
            u._emit("error");
        }
    };

    setWindowProp("WebSpeechSynthKit", {coordinator: coordinator});
    setWindowProp("speechSynthesis", speechSynthesisShim);
    setWindowProp("SpeechSynthesisUtterance", ScrubUtterance);
})();

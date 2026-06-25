//
// speech-inject.js
//
// Replaces the WKWebView's non-functional SpeechRecognition with a shim that
// bridges to the native SFSpeechRecognizer (see WebSpeech.swift). Injected at
// document start so pages and extensions pick up the working implementation.
//
(function () {
    "use strict";

    if (!window.webkit ||
        !window.webkit.messageHandlers ||
        !window.webkit.messageHandlers.speechStart) {
        return; // native bridge is not available
    }

    var post = function (name, body) {
        try {
            window.webkit.messageHandlers[name].postMessage(body);
        } catch (e) {
            // ignore
        }
    };

    var instances = new Map();
    var nextId = 1;

    var makeResultList = function (transcript, isFinal) {
        var alternative = {transcript: transcript, confidence: 1.0};
        var result = [alternative];
        result.isFinal = isFinal;
        result.item = function (i) { return this[i]; };
        var list = [result];
        list.item = function (i) { return this[i]; };
        return list;
    };

    function ScrubSpeechRecognition() {
        this.lang = "";
        this.continuous = false;
        this.interimResults = false;
        this.maxAlternatives = 1;
        this.grammars = null;
        this.serviceURI = null;

        this.onstart = null;
        this.onaudiostart = null;
        this.onspeechstart = null;
        this.onspeechend = null;
        this.onaudioend = null;
        this.onresult = null;
        this.onnomatch = null;
        this.onerror = null;
        this.onend = null;

        this._listeners = {};
        this._id = 0;
        this._started = false;
    }

    ScrubSpeechRecognition.prototype.addEventListener = function (type, fn) {
        (this._listeners[type] = this._listeners[type] || []).push(fn);
    };

    ScrubSpeechRecognition.prototype.removeEventListener = function (type, fn) {
        var a = this._listeners[type];
        if (!a) { return; }
        var i = a.indexOf(fn);
        if (i >= 0) { a.splice(i, 1); }
    };

    ScrubSpeechRecognition.prototype._emit = function (type, event) {
        event = event || {};
        event.type = type;
        if (!event.target) { event.target = this; }
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

    ScrubSpeechRecognition.prototype.start = function () {
        if (this._started) {
            throw new DOMException("recognition has already started", "InvalidStateError");
        }
        this._started = true;
        this._id = nextId++;
        instances.set(this._id, this);
        post("speechStart", {
            id: this._id,
            lang: this.lang || "",
            interimResults: !!this.interimResults,
            continuous: !!this.continuous,
            maxAlternatives: this.maxAlternatives || 1
        });
    };

    ScrubSpeechRecognition.prototype.stop = function () {
        if (!this._started) { return; }
        post("speechStop", {id: this._id});
    };

    ScrubSpeechRecognition.prototype.abort = function () {
        if (!this._started) { return; }
        post("speechAbort", {id: this._id});
    };

    // Called from native (see WebSpeech.swift).
    ScrubSpeechRecognition.prototype._onstart = function () {
        this._emit("start");
        this._emit("audiostart");
        this._emit("speechstart");
    };

    ScrubSpeechRecognition.prototype._onresult = function (transcript, isFinal) {
        var results = makeResultList(transcript, isFinal);
        this._emit("result", {results: results, resultIndex: 0});
    };

    ScrubSpeechRecognition.prototype._onerror = function (error) {
        this._emit("error", {error: error, message: error});
    };

    ScrubSpeechRecognition.prototype._onend = function () {
        if (!this._started) { return; }
        this._started = false;
        instances.delete(this._id);
        this._emit("speechend");
        this._emit("audioend");
        this._emit("end");
    };

    var coordinator = {
        receiveStart: function (id) {
            var r = instances.get(id);
            if (r) { r._onstart(); }
        },
        receiveResult: function (id, transcript, isFinal) {
            var r = instances.get(id);
            if (r) { r._onresult(transcript, isFinal); }
        },
        receiveError: function (id, error) {
            var r = instances.get(id);
            if (r) { r._onerror(error); }
        },
        receiveEnd: function (id) {
            var r = instances.get(id);
            if (r) { r._onend(); }
        }
    };

    window.WebSpeechKit = {coordinator: coordinator};

    ScrubSpeechRecognition.__scrubNative = true;
    window.SpeechRecognition = ScrubSpeechRecognition;
    window.webkitSpeechRecognition = ScrubSpeechRecognition;

    // Minimal no-op grammar lists for API compatibility.
    function ScrubSpeechGrammarList() { this.length = 0; }
    ScrubSpeechGrammarList.prototype.addFromString = function () {};
    ScrubSpeechGrammarList.prototype.addFromURI = function () {};
    window.SpeechGrammarList = ScrubSpeechGrammarList;
    window.webkitSpeechGrammarList = ScrubSpeechGrammarList;
})();

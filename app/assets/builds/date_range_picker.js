(function () {
  if (window.__sternDateRangeInit) return;
  window.__sternDateRangeInit = true;

  var DT = (window.luxon && window.luxon.DateTime) || null;
  var INPUT_FMT = "yyyy-LL-dd'T'HH:mm";
  var LABEL_FMT = "LLL d, HH:mm";

  function nowIn(tz) { return DT.now().setZone(tz); }
  function fromInput(value, tz) { return DT.fromFormat(value, INPUT_FMT, { zone: tz }); }
  function fmtInput(dt) { return dt.toFormat(INPUT_FMT); }
  function fmtLabel(value, tz) {
    if (!value) return "";
    var dt = fromInput(value, tz);
    return dt.isValid ? dt.toFormat(LABEL_FMT) : value;
  }

  function startOfDay(dt) { return dt.startOf("day"); }
  function endOfDay(dt)   { return dt.set({ hour: 23, minute: 59, second: 0, millisecond: 0 }); }

  function presetRange(key, tz) {
    var now = nowIn(tz);
    switch (key) {
      case "today":
        return [startOfDay(now), endOfDay(now)];
      case "yesterday": {
        var y = now.minus({ days: 1 });
        return [startOfDay(y), endOfDay(y)];
      }
      case "this_week":
        return [now.startOf("week"), endOfDay(now.endOf("week"))];
      case "last_week": {
        var w = now.minus({ weeks: 1 });
        return [w.startOf("week"), endOfDay(w.endOf("week"))];
      }
      case "this_month":
        return [now.startOf("month"), endOfDay(now.endOf("month"))];
      case "last_month": {
        var m = now.minus({ months: 1 });
        return [m.startOf("month"), endOfDay(m.endOf("month"))];
      }
      case "this_quarter":
        return [now.startOf("quarter"), endOfDay(now.endOf("quarter"))];
      case "last_quarter": {
        var q = now.minus({ quarters: 1 });
        return [q.startOf("quarter"), endOfDay(q.endOf("quarter"))];
      }
      case "this_year":
        return [now.startOf("year"), endOfDay(now.endOf("year"))];
      case "last_year": {
        var ly = now.minus({ years: 1 });
        return [ly.startOf("year"), endOfDay(ly.endOf("year"))];
      }
    }
    return null;
  }

  function syncLabel(root, tz, tzAbbr) {
    var label = root.querySelector("[data-bs-date-range-label]");
    var startInput = root.querySelector("[data-bs-date-range-start]");
    var endInput = root.querySelector("[data-bs-date-range-end]");
    if (!label || !startInput || !endInput) return;
    var s = fmtLabel(startInput.value, tz);
    var e = fmtLabel(endInput.value, tz);
    if (s && e) label.textContent = s + " → " + e + (tzAbbr ? " " + tzAbbr : "");
    else label.textContent = "Select range";
  }

  function init(root) {
    if (!DT) {
      console.warn("Luxon not loaded; date range picker presets will be skipped.");
      return;
    }
    var tz = root.getAttribute("data-bs-tz") || "UTC";
    var tzAbbr = root.getAttribute("data-bs-tz-abbr") || "";
    var toggle = root.querySelector("[data-bs-date-range-toggle]");
    var modal = root.querySelector("[data-bs-date-range-modal]");
    var dialog = root.querySelector("[data-bs-date-range-dialog]");
    var startInput = root.querySelector("[data-bs-date-range-start]");
    var endInput = root.querySelector("[data-bs-date-range-end]");
    var snapshot = { start: startInput.value, end: endInput.value };

    function open() {
      snapshot.start = startInput.value;
      snapshot.end = endInput.value;
      modal.classList.remove("hidden");
    }
    function close() { modal.classList.add("hidden"); }
    function cancel() {
      startInput.value = snapshot.start;
      endInput.value = snapshot.end;
      syncLabel(root, tz, tzAbbr);
      close();
    }

    toggle.addEventListener("click", function (e) { e.preventDefault(); open(); });

    modal.addEventListener("click", function (e) {
      if (!dialog.contains(e.target)) cancel();
    });

    root.querySelectorAll("[data-bs-date-range-close]").forEach(function (btn) {
      btn.addEventListener("click", function (e) { e.preventDefault(); cancel(); });
    });
    root.querySelectorAll("[data-bs-date-range-cancel]").forEach(function (btn) {
      btn.addEventListener("click", function (e) { e.preventDefault(); cancel(); });
    });

    [startInput, endInput].forEach(function (inp) {
      inp.addEventListener("change", function () { syncLabel(root, tz, tzAbbr); });
    });

    root.querySelectorAll("[data-bs-date-range-preset]").forEach(function (btn) {
      btn.addEventListener("click", function (e) {
        e.preventDefault();
        var range = presetRange(btn.getAttribute("data-bs-date-range-preset"), tz);
        if (!range) return;
        startInput.value = fmtInput(range[0]);
        endInput.value = fmtInput(range[1]);
        syncLabel(root, tz, tzAbbr);
        close();
        var form = startInput.form;
        if (form) {
          if (typeof form.requestSubmit === "function") form.requestSubmit();
          else form.submit();
        }
      });
    });

    document.addEventListener("keydown", function (e) {
      if (e.key === "Escape" && !modal.classList.contains("hidden")) cancel();
    });

    syncLabel(root, tz, tzAbbr);
  }

  function initAll() {
    document.querySelectorAll("[data-bs-date-range]").forEach(function (root) {
      if (root.__sternDateRangeInited) return;
      root.__sternDateRangeInited = true;
      init(root);
    });
  }

  document.addEventListener("DOMContentLoaded", initAll);
  if (document.readyState !== "loading") initAll();
})();

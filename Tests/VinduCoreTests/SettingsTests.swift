import Testing
@testable import VinduCore

struct SettingsTests {
    @Test func setAndGetRoundTrip() {
        var s = Settings()
        #expect(s.set("general:gaps_in", "12") == nil)
        #expect(s.get("general:gaps_in") == "12.0")
        #expect(s.set("general:layout", "master") == nil)
        #expect(s.get("general:layout") == "master")
        #expect(s.set("master:orientation", "center") == nil)
        #expect(s.get("master:orientation") == "center")
        #expect(s.set("misc:focus_on_activate", "yes") == nil)
        #expect(s.get("misc:focus_on_activate") == "true")
    }

    @Test func gradientRoundTrip() {
        var s = Settings()
        #expect(s.set("general:col.active_border", "rgba(33ccffee) rgba(00ff99ee) 45deg") == nil)
        #expect(s.get("general:col.active_border") == "rgba(33ccffee) rgba(00ff99ee) 45deg")
        #expect(s.set("general:col.inactive_border", "rgba(595959aa)") == nil)
        #expect(s.get("general:col.inactive_border") == "rgba(595959aa)")
    }

    @Test func rangeAndTypeValidation() {
        var s = Settings()
        #expect(s.set("master:mfact", "1.5") != nil)
        #expect(s.set("dwindle:force_split", "9") != nil)
        #expect(s.set("dwindle:default_split_ratio", "0.05") != nil)
        #expect(s.set("general:gaps_in", "abc") != nil)
        #expect(s.set("master:new_status", "boss") != nil)
        #expect(s.set("master:new_status", "master") == nil)
    }

    @Test func typosInModeledSectionsAreReported() {
        var s = Settings()
        #expect(s.set("dwindle:preserve_splitt", "true") != nil)
        #expect(s.set("general:gapsin", "5") != nil)
        #expect(s.set("nope:nope", "1") != nil)
    }

    @Test func knownHyprlandKeysAreTolerated() {
        var s = Settings()
        #expect(s.set("input:kb_layout", "us") == nil)
        #expect(s.set("animations:enabled", "true") == nil)
        #expect(s.set("animations:bezier_thing", "whatever") == nil)
        #expect(s.set("decoration:blur:size", "3") == nil)
        #expect(s.set("misc:vfr", "true") == nil)
        #expect(s.set("gestures:workspace_swipe", "true") == nil)
        #expect(s.set("general:resize_on_border", "true") == nil)
        #expect(s.set("dwindle:pseudotile", "true") == nil)
        #expect(s.set("dwindle:preserve_split", "true") == nil)
    }
}

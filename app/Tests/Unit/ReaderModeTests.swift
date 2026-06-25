import Testing
import Foundation
@testable import PinkhaCore

// Unit tests for the reader-mode controller and its settings. The
// `MultiFingerLongPress` UIView bridge is not unit-tested here — it
// needs a real touch session, which lands in a future UI test.

@MainActor
@Suite("ReaderMode — controller state")
struct ReaderModeTests {

    @Test func defaults_to_inactive() {
        let r = ReaderMode()
        #expect(r.isActive == false)
    }

    @Test func toggle_flips_state() {
        let r = ReaderMode()
        r.toggle()
        #expect(r.isActive == true)
        r.toggle()
        #expect(r.isActive == false)
    }

    @Test func deactivate_flips_when_active() {
        let r = ReaderMode()
        r.toggle()
        r.deactivate()
        #expect(r.isActive == false)
    }

    @Test func deactivate_noops_when_already_inactive() {
        let r = ReaderMode()
        // Should not throw, should not flip to true.
        r.deactivate()
        #expect(r.isActive == false)
    }
}

@MainActor
@Suite("AppSettings — reader mode defaults & persistence")
struct AppSettingsReaderTests {

    /// Clears the reader-mode + accessory keys so each test starts
    /// from a clean UserDefaults — otherwise a previous test run's
    /// value leaks in.
    private func clearReaderKeys() {
        let keys = [
            "pinkha.settings.readerLongPressEnabled",
            "pinkha.settings.readerLongPressFingerCount",
            "pinkha.settings.readerHidesStatusBar",
            "pinkha.settings.hidesAccessoryOutsideLibraryRoot",
        ]
        for key in keys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    @Test func default_long_press_is_enabled() {
        clearReaderKeys()
        let s = AppSettings()
        #expect(s.readerLongPressEnabled == true)
    }

    @Test func default_finger_count_is_two() {
        clearReaderKeys()
        let s = AppSettings()
        #expect(s.readerLongPressFingerCount == 2)
    }

    @Test func default_status_bar_stays_visible() {
        clearReaderKeys()
        let s = AppSettings()
        #expect(s.readerHidesStatusBar == false)
    }

    @Test func finger_count_clamps_to_2_or_3() {
        clearReaderKeys()
        let s = AppSettings()
        s.readerLongPressFingerCount = 1
        #expect(s.readerLongPressFingerCount == 2) // clamped up
        s.readerLongPressFingerCount = 5
        #expect(s.readerLongPressFingerCount == 3) // clamped down
        s.readerLongPressFingerCount = 3
        #expect(s.readerLongPressFingerCount == 3) // accepted as-is
    }

    @Test func reset_to_defaults_restores_reader_settings() {
        clearReaderKeys()
        let s = AppSettings()
        s.readerLongPressEnabled = false
        s.readerLongPressFingerCount = 3
        s.readerHidesStatusBar = true
        s.resetToDefaults()
        #expect(s.readerLongPressEnabled == true)
        #expect(s.readerLongPressFingerCount == 2)
        #expect(s.readerHidesStatusBar == false)
    }

    // MARK: - PRO-60 : auto-hide accessory outside library root.

    @Test func default_accessory_auto_hide_is_on() {
        clearReaderKeys()
        let s = AppSettings()
        #expect(s.hidesAccessoryOutsideLibraryRoot == true)
    }

    @Test func accessory_auto_hide_round_trips() {
        clearReaderKeys()
        let s = AppSettings()
        s.hidesAccessoryOutsideLibraryRoot = false
        let s2 = AppSettings()
        #expect(s2.hidesAccessoryOutsideLibraryRoot == false)
    }

    @Test func reset_to_defaults_restores_accessory_auto_hide() {
        clearReaderKeys()
        let s = AppSettings()
        s.hidesAccessoryOutsideLibraryRoot = false
        s.resetToDefaults()
        #expect(s.hidesAccessoryOutsideLibraryRoot == true)
    }
}

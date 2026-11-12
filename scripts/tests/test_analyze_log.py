import importlib.util
import pathlib
import unittest

_path = pathlib.Path(__file__).resolve().parent.parent / "analyze-log.py"
_spec = importlib.util.spec_from_file_location("analyze_log", _path)
analyze_log = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(analyze_log)


def event(millisecond, name, **details):
    return {"timestamp": f"2026-11-12T12:00:{millisecond // 1000:02d}.{millisecond % 1000:03d}Z",
            "event": name, "details": details}


class NavigationStatsTests(unittest.TestCase):
    def test_overlapping_actions_are_timed_from_their_own_queue_time(self):
        nav, counts = analyze_log.navigation_stats([
            event(0, "change_queued", changeID="1", operation="action.focusNext"),
            event(100, "change_queued", changeID="2", operation="action.focusNext"),
            event(110, "change_started", changeID="1", operation="action.focusNext"),
            event(120, "ribbon_animation_started"),
            event(300, "navigation_focus_confirmed", focusConfirmed="true"),
            event(320, "change_completed", changeID="1", operation="action.focusNext"),
            event(330, "change_started", changeID="2", operation="action.focusNext"),
            event(340, "ribbon_animation_started"),
            event(500, "navigation_focus_confirmed", focusConfirmed="true"),
            event(520, "change_completed", changeID="2", operation="action.focusNext"),
        ])
        self.assertEqual(nav["action -> first motion"], [120, 240])
        self.assertEqual(nav["action -> focus confirmed"], [300, 400])
        self.assertEqual(nav["action -> settled"], [320, 420])
        self.assertEqual(counts["actions"], 2)

    def test_merged_and_cancelled_actions_are_counted_incomplete_not_timed(self):
        nav, counts = analyze_log.navigation_stats([
            event(0, "change_queued", changeID="1", operation="action.focusNext"),
            event(10, "change_queued", changeID="2", operation="action.focusNext"),
            event(20, "change_queued", changeID="3", operation="action.focusNext"),
            event(30, "change_started", changeID="1", operation="action.focusNext"),
            event(40, "change_started", changeID="2", operation="action.focusNext"),
            event(50, "ribbon_animation_started"),
            event(200, "change_completed", changeID="2", operation="action.focusNext"),
        ])
        self.assertEqual(nav["action -> settled"], [190])
        self.assertEqual(nav["action -> first motion"], [40])
        self.assertEqual(counts["incomplete: started, never completed"], 1)
        self.assertEqual(counts["incomplete: never started"], 1)

    def test_rejected_focus_is_counted_and_not_timed_as_confirmed(self):
        nav, counts = analyze_log.navigation_stats([
            event(0, "change_queued", changeID="1", operation="action.focusNext"),
            event(10, "change_started", changeID="1", operation="action.focusNext"),
            event(900, "navigation_focus_confirmed", focusConfirmed="false"),
        ])
        self.assertEqual(nav["action -> focus confirmed"], [])
        self.assertEqual(counts["focus rejected"], 1)

    def test_logs_without_change_ids_pair_by_queue_order(self):
        nav, counts = analyze_log.navigation_stats([
            event(0, "change_queued", operation="action.focusNext"),
            event(5, "change_queued", operation="refresh"),
            event(100, "change_queued", operation="action.focusPrevious"),
            event(110, "change_started", operation="action.focusNext"),
            event(320, "change_completed", operation="action.focusNext"),
            event(330, "change_started", operation="refresh"),
            event(340, "change_completed", operation="refresh"),
            event(350, "change_started", operation="action.focusPrevious"),
            event(520, "change_completed", operation="action.focusPrevious"),
        ])
        self.assertEqual(nav["action -> settled"], [320, 420])
        self.assertEqual(counts["actions"], 2)


if __name__ == "__main__":
    unittest.main()

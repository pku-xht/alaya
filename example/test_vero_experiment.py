"""Budget and waiting-state contracts, without paid model calls or Vero imports."""
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import vero_experiment as experiment


class RunnerTests(unittest.TestCase):
    def test_waiting_exit_three_is_a_successful_question(self):
        with tempfile.TemporaryDirectory() as td:
            binary = Path(td) / "model"
            binary.write_text('#!/usr/bin/env python3\nimport json\n'
                              'print(json.dumps({"state":"q", "question":"help?", "outcome":None}))\n'
                              'raise SystemExit(3)\n')
            binary.chmod(0o700)
            result = experiment.step(binary, Path(td), "mini-ask", "parent", 5)
            self.assertEqual(result["state"], "q")

    def test_submission_stops_without_using_up_budget(self):
        with tempfile.TemporaryDirectory() as td, patch.object(experiment, "step") as step:
            step.return_value = {"state": "done", "outcome": "Submitted", "question": None}
            result = experiment.continue_run(Path("alaya"), Path(td), "mini-swe", "root", 1800, Path(td)/"run.json")
            self.assertEqual(step.call_count, 1)
            self.assertEqual(result["stop_reason"], "Submitted")
            self.assertLess(result["elapsed_seconds"], 1)

    def test_timeout_keeps_last_committed_state(self):
        with tempfile.TemporaryDirectory() as td, patch.object(experiment, "step") as step:
            step.side_effect = [
                {"state": "saved", "outcome": None, "question": None},
                subprocess.TimeoutExpired("test", .01)]
            result = experiment.continue_run(Path("alaya"), Path(td), "mini-swe", "root", 10, Path(td)/"run.json")
            self.assertEqual(result["terminal"], "saved")
            self.assertIn("in_flight_turn_discarded", result["stop_reason"])
            self.assertEqual(len(result["steps"]), 1)

    def test_extra_question_gets_no_further_help_and_lineage_is_kept(self):
        with tempfile.TemporaryDirectory() as td, patch.object(experiment, "step") as step, patch.object(experiment, "call", return_value="reply"):
            step.side_effect = [
                {"state": "question", "outcome": None, "question": "more?"},
                {"state": "done", "outcome": "Submitted", "question": None}]
            result = experiment.continue_run(Path("alaya"), Path(td), "mini-ask", "root", 10, Path(td)/"run.json", no_more_help=True)
            self.assertEqual(result["replies"][0]["question"], "question")
            self.assertEqual(step.call_args_list[1].args[3], "reply")


if __name__ == "__main__":
    unittest.main()

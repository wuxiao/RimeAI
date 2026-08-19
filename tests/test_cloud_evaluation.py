from rimeai_eval.cloud_evaluation import evaluate_cloud_observations


def _observation(index: int) -> dict:
    correct_fuzzy = index < 49
    return {
        "gold_text": "正确" if index < 50 else "首选",
        "baseline_candidates": ["首选"],
        "expanded_candidates": ["首选", "正确"],
        "decision": "choose" if index < 50 else "keep",
        "selected_text": (
            "正确" if correct_fuzzy else "首选"
        ) if index < 50 else None,
        "selected_source": "rime_fuzzy" if index < 50 else "rime_exact",
        "latency_ms": 700 if index < 95 else 900,
        "secure_input": False,
        "inference_sent": True,
        "history_written": True,
        "stale_commit": False,
    }


def test_cloud_gates_measure_precision_coverage_latency_and_privacy():
    report = evaluate_cloud_observations(
        [_observation(index) for index in range(100)]
    )

    assert report["metrics"]["candidate_coverage_gain_pp"] == 50
    assert report["metrics"]["correction_precision"] == 0.98
    assert report["metrics"]["within_800_ms_rate"] == 0.95
    assert report["passed"] is True


def test_missing_cloud_results_count_as_deadline_misses():
    observations = [_observation(index) for index in range(100)]
    for observation in observations[50:]:
        observation["latency_ms"] = None

    report = evaluate_cloud_observations(observations)

    assert report["metrics"]["completed_cloud_requests"] == 50
    assert report["metrics"]["within_800_ms_rate"] == 0.5
    assert report["gates"]["cloud_within_800ms_at_least_95pct"] is False
    assert report["passed"] is False

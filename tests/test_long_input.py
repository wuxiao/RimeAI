from rimeai_eval.long_input import derive_long_target


def test_derive_long_target_keeps_the_original_text_boundary():
    context = "这份报告已经说明我们需要进一步提高系统的整体运行"

    derived = derive_long_target(context, "效率")

    assert derived is not None
    short_context, long_target = derived
    assert short_context + long_target == context + "效率"
    assert 6 <= len(long_target) <= 12
    assert len(short_context) >= 8


def test_derive_long_target_rejects_a_non_han_boundary():
    assert derive_long_target("请检查 API timeout ", "配置") is None


def test_derive_long_target_rejects_context_that_would_become_too_short():
    assert derive_long_target("整体运行", "效率") is None

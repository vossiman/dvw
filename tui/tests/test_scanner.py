import pytest
from rich.text import Text

from dvw_tui.palette import TOKYO
from dvw_tui.scanner import scanner_frames, scanner_settled
from dvw_tui.wordmark import wordmark

ART = wordmark()


def styles(text: Text) -> list[str]:
    return [str(span.style) for span in text.spans]


def delta(a: Text, b: Text) -> int:
    return sum(1 for x, y in zip(styles(a), styles(b)) if x != y)


def test_frame_count_follows_the_period():
    slow = scanner_frames(ART, TOKYO, 900, fps=30)
    fast = scanner_frames(ART, TOKYO, 300, fps=30)
    assert len(slow) == pytest.approx(27, abs=1)
    assert len(fast) == pytest.approx(9, abs=1)


def test_frame_rate_is_respected():
    assert len(scanner_frames(ART, TOKYO, 1000, fps=10)) == pytest.approx(10, abs=1)


def test_loop_first_and_last_frames_differ():
    frames = scanner_frames(ART, TOKYO, 900, loop=True)
    assert styles(frames[0]) != styles(frames[-1])


def test_one_shot_first_and_last_frames_match():
    frames = scanner_frames(ART, TOKYO, 900, loop=False)
    assert styles(frames[0]) == styles(frames[-1])


def test_loop_seam_is_indistinguishable_from_a_normal_step():
    frames = scanner_frames(ART, TOKYO, 900, loop=True)
    steps = [delta(frames[i], frames[i + 1]) for i in range(len(frames) - 1)]
    wrap = delta(frames[-1], frames[0])
    assert min(steps) <= wrap <= max(steps)


def test_every_frame_draws_the_complete_wordmark():
    frames = scanner_frames(ART, TOKYO, 900, loop=True)
    counts = {frame.plain.count("█") for frame in frames}
    assert len(counts) == 1
    assert counts.pop() > 0


def test_block_is_equal_width_with_no_blank_edges():
    frame = scanner_frames(ART, TOKYO, 900)[0]
    rows = frame.plain.split("\n")
    assert len({len(row) for row in rows}) == 1
    assert rows[0].strip() and rows[-1].strip()


def test_settled_is_a_single_uniform_colour():
    settled = scanner_settled(ART, TOKYO)
    assert len({str(span.style) for span in settled.spans}) == 1


def test_zero_period_degrades_to_one_settled_frame():
    frames = scanner_frames(ART, TOKYO, 0)
    assert len(frames) == 1
    assert len({str(span.style) for span in frames[0].spans}) == 1


def test_a_palette_missing_roles_degrades_instead_of_raising():
    frames = scanner_frames(ART, {}, 900)
    assert len(frames) == 1

from dvw_tui.wordmark import DVW_ART, wordmark


def test_art_is_six_lines_of_twenty_seven_columns():
    assert len(DVW_ART) == 6
    assert {len(line) for line in DVW_ART} == {27}


def test_block_lines_are_all_equal_width():
    lines = wordmark().split("\n")
    assert len({len(line) for line in lines}) == 1


def test_block_has_no_leading_or_trailing_blank_rows():
    lines = wordmark().split("\n")
    assert lines[0].strip()
    assert lines[-1].strip()


def test_subtitle_is_centred_under_the_art():
    lines = wordmark("abc").split("\n")
    subtitle_line = lines[-1]
    lead = len(subtitle_line) - len(subtitle_line.lstrip())
    trail = len(subtitle_line) - len(subtitle_line.rstrip())
    assert abs(lead - trail) <= 1


def test_a_long_subtitle_widens_the_block_instead_of_overflowing():
    long = "x" * 60
    lines = wordmark(long).split("\n")
    assert len({len(line) for line in lines}) == 1
    assert len(lines[0]) >= 60


def test_there_is_a_blank_row_between_art_and_subtitle():
    lines = wordmark().split("\n")
    assert not lines[-2].strip()

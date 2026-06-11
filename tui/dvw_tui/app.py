"""App entry point. Screens and behavior grow in later tasks."""

from __future__ import annotations

from textual.app import App


class DvwApp(App):
    """dvw workspace control center."""

    CSS_PATH = "theme.tcss"
    TITLE = "dvw"


def main() -> None:
    DvwApp().run()


if __name__ == "__main__":
    main()

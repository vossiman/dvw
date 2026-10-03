import httpx
import pytest
from dvw_tui.client import CatalogClient
from dvw_tui import render
from tests.test_client import ok_handler


def record():
    return dict(workspace_id='alpha', state='idle', reasons=[], observed_at=1000,
                idle_since=400, idle_seconds=600, timeout_seconds=3600,
                remaining_seconds=3000, observation_only=True)


async def test_activity_is_merged_and_old_server_is_unknown():
    def handler(request):
        if request.url.path == '/v1/containers/activity':
            return httpx.Response(200, json=[record()])
        return ok_handler(request)
    client = CatalogClient(transport=httpx.MockTransport(handler))
    ws = await client.workspaces_with_status()
    assert ws[0].activity['idle_seconds'] == 600
    assert ws[1].activity is None
    await client.aclose()
    client = CatalogClient(transport=httpx.MockTransport(ok_handler))
    assert (await client.workspaces_with_status())[0].activity is None
    await client.aclose()


@pytest.mark.parametrize('bad', [None, {'state': 'idle'}, [None],
    [{'workspace_id': []}], [{**record(), 'state': []}],
    [{**record(), 'reasons': ['\x1b[31mspoof']}],
    [{**record(), 'idle_seconds': True}],
    [{**record(), 'remaining_seconds': -1}],
    [{**record(), 'observed_at': 1e100}],
    [{**record(), 'observation_only': 'no'}], [record(), record()],
])
async def test_malformed_activity_cannot_show_an_idle_countdown(bad):
    client = CatalogClient(transport=httpx.MockTransport(
        lambda request: httpx.Response(200, json=bad)))
    assert await client.activities() == {}
    await client.aclose()


def test_overview_row_shows_only_idle_minutes():
    assert render.activity_cell(record()).plain == 'idle 10m'
    assert render.activity_row_cell(record()).plain == 'idle 10m'
    assert render.activity_cell({**record(), 'remaining_seconds': 0}).plain == 'idle 10m'
    active = {**record(), 'state': 'active', 'reasons': ['cursor', 'tmux']}
    assert render.activity_cell(active).plain == 'Cursor connected, tmux'
    assert render.activity_row_cell(active).plain == render.ACTIVE_MARK
    assert render.activity_cell(None).plain == 'activity unknown'
    assert render.activity_row_cell(None).plain == 'activity unknown'
    assert render.activity_cell({**record(), 'state': 'always-on'}).plain == 'always-on'
    t3 = {**record(), 'state': 'always-on', 'reasons': ['t3']}
    assert render.activity_cell(t3).plain == 'always-on (t3)'


def test_sidebar_lines_in_observation_mode():
    entry = {**record(), 'signals': {'tmux_sessions': 0, 'terminals': 0, 'agents': 0,
                                     'cursor_connections': 0, 'vscode_connections': 0,
                                     't3_servers': 0}}
    lines = render.activity_lines(entry, now=1012)
    assert [label for label, _ in lines] == [
        'activity', 'would stop in', 'mode', 'signals', 'idle since', 'observed', 'timeout']
    d = dict(lines)
    assert d['activity'] == 'idle 10m'
    assert d['would stop in'] == '50m'
    assert d['mode'] == 'observation-only'
    assert d['signals'] == 'none'
    assert d['idle since'].endswith('(10m ago)')
    assert d['observed'].endswith('(12s ago)')
    assert d['timeout'] == '60m'


def test_sidebar_lines_when_enforcing():
    entry = {**record(), 'observation_only': False, 'remaining_seconds': 0}
    d = dict(render.activity_lines(entry, now=1000))
    assert d['stops in'] == 'now' and 'would stop in' not in d
    assert d['mode'] == 'automatic stop'


def test_sidebar_signals_lists_non_zero_counts():
    entry = {**record(), 'state': 'active', 'reasons': ['tmux', 'terminal', 'agent'],
             'signals': {'tmux_sessions': 1, 'terminals': 3, 'agents': 2,
                         'cursor_connections': 0, 'vscode_connections': 0, 't3_servers': 0}}
    d = dict(render.activity_lines(entry, now=1000))
    assert d['signals'] == 'tmux 1 · terminals 3 · agents 2'
    assert 'stops in' not in d and 'would stop in' not in d      # only when idle


def test_sidebar_signals_unknown_when_empty():
    d = dict(render.activity_lines({**record(), 'signals': {}}, now=1000))
    assert d['signals'] == 'unknown'


def test_sidebar_signals_unknown_when_any_value_is_null():
    entry = {**record(), 'signals': {'tmux_sessions': 0, 'terminals': None, 'agents': 0}}
    assert dict(render.activity_lines(entry, now=1000))['signals'] == 'unknown'


def test_sidebar_signals_none_when_all_zero():
    entry = {**record(), 'signals': {'tmux_sessions': 0, 'terminals': 0}}
    assert dict(render.activity_lines(entry, now=1000))['signals'] == 'none'


def test_sidebar_last_stop_line():
    stopped = {**record(), 'state': 'stopped', 'idle_since': None, 'idle_seconds': None,
               'remaining_seconds': None,
               'stop': {'result': 'stopped', 'at': 940, 'idle_seconds': 3600}}
    d = dict(render.activity_lines(stopped, now=1000))
    assert d['last stop'].startswith('auto-stopped ') and d['last stop'].endswith('after 60m idle')
    failed = {**record(), 'stop': {'result': 'failed', 'at': 940, 'idle_seconds': 3600}}
    assert dict(render.activity_lines(failed, now=1000))['last stop'].startswith('stop failed ')
    assert 'last stop' not in dict(render.activity_lines(record(), now=1000))


def test_unparseable_entry_shows_unknown_mode():
    d = dict(render.activity_lines({'state': 'nonsense'}, now=1000))
    assert d == {'activity': 'activity unknown', 'mode': 'unknown'}


def test_old_shape_entry_still_parses():
    from dvw_tui.client import parse_activity
    clean = parse_activity(record())                 # no signals, no stop
    assert clean['observation_only'] is True
    assert clean['signals'] == {} and clean['stop'] is None


def test_new_fields_are_parsed_and_bounded():
    from dvw_tui.client import parse_activity
    base = {**record(), 'observation_only': False, 'state': 'always-on', 'reasons': ['t3'],
            'signals': {'tmux_sessions': 1, 't3_servers': 1, 'terminals': None, 'junk': 5},
            'stop': {'result': 'stopped', 'at': 940, 'idle_seconds': 3600}}
    clean = parse_activity(base)
    assert clean['observation_only'] is False and clean['reasons'] == ['t3']
    assert clean['signals'] == {'tmux_sessions': 1, 't3_servers': 1, 'terminals': None}
    assert clean['stop'] == {'result': 'stopped', 'at': 940, 'idle_seconds': 3600}
    assert parse_activity({**base, 'observation_only': 'no'}) is None
    assert parse_activity({**base, 'signals': {'tmux_sessions': -1}})['signals'] == {}
    assert parse_activity({**base, 'signals': 'x'})['signals'] == {}
    assert parse_activity({**base, 'stop': {'result': 'exploded', 'at': 1}})['stop'] is None
    assert parse_activity({**base, 'stop': {'result': 'stopped', 'at': 'yesterday'}})['stop'] is None


async def test_tree_and_cached_inspect_use_latest_activity(fake_client):
    from dvw_tui.app import DvwApp
    from dvw_tui.screens.main import WorkspaceTree
    fake_client._workspaces[0].activity = record()
    fake_client._workspaces[1].activity = record()
    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause(0.4)
        nodes = app.screen.query_one(WorkspaceTree).root.children
        assert 'idle 10m' in nodes[0].label.plain
        assert 'would stop' not in nodes[0].label.plain
        assert 'would stop' not in nodes[1].label.plain
        assert 'observation-only' in str(app.query_one('#inspect-body').content)
        assert 'would stop in' in str(app.query_one('#inspect-body').content)
        # Keep the cached inspect response but refresh the workspace activity.
        fake_client._workspaces[0].activity = {**record(), 'state': 'active', 'reasons': ['cursor']}
        app.screen._render_inspect('alpha', app.screen._inspect_cache['alpha'])
        app.screen._render_tree()
        row = app.screen.query_one(WorkspaceTree).root.children[0].label.plain
        assert 'Cursor' not in row and render.ACTIVE_MARK in row
        assert 'Cursor connected' in str(app.query_one('#inspect-body').content)
        assert 'would stop in' not in str(app.query_one('#inspect-body').content)


async def test_catalog_failure_clears_previous_idle_countdown(fake_client):
    from dvw_tui.app import DvwApp
    from dvw_tui.client import CatalogError
    from dvw_tui.screens.main import WorkspaceTree
    fake_client._workspaces[0].activity = record()
    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause(0.4)
        async def failed():
            raise CatalogError('offline')
        fake_client.workspaces_with_status = failed
        app.screen.refresh_data()
        await pilot.pause(0.4)
        label = app.screen.query_one(WorkspaceTree).root.children[0].label.plain
        assert 'activity unknown' in label
        assert 'would stop' not in str(app.query_one('#inspect-body').content)


async def test_stopped_workspace_shows_its_last_stop(fake_client):
    from dvw_tui.app import DvwApp
    fake_client._workspaces[1].activity = {
        **record(), 'workspace_id': 'beta', 'state': 'stopped', 'idle_since': None,
        'idle_seconds': None, 'remaining_seconds': None, 'observation_only': False,
        'stop': {'result': 'stopped', 'at': 940, 'idle_seconds': 3600}}
    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause(0.4)
        app.screen._render_inspect('beta', fake_client._inspect['beta'])
        body = str(app.query_one('#inspect-body').content)
        assert 'auto-stopped' in body and 'after 60m idle' in body
        assert 'automatic stop' in body

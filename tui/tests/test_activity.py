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
    [{**record(), 'observation_only': False}], [record(), record()],
])
async def test_malformed_activity_cannot_show_an_idle_countdown(bad):
    client = CatalogClient(transport=httpx.MockTransport(
        lambda request: httpx.Response(200, json=bad)))
    assert await client.activities() == {}
    await client.aclose()


def test_activity_rendering_uses_server_durations():
    assert render.activity_cell(record()).plain == 'idle 10m · would stop in 50m'
    assert render.activity_cell({**record(), 'remaining_seconds': 0}).plain.endswith('would stop now')
    assert render.activity_cell({**record(), 'state': 'active', 'reasons': ['cursor', 'tmux']}).plain == 'Cursor connected, tmux'
    assert render.activity_cell(None).plain == 'activity unknown'
    assert render.activity_cell({**record(), 'state': 'always-on'}).plain == 'always-on'
    details = dict(render.activity_lines(record()))
    assert details['mode'] == 'observation-only; no automatic stops'
    assert details['timeout'] == '60m'
    assert '1970' in details['idle since']


async def test_tree_and_cached_inspect_use_latest_activity(fake_client):
    from dvw_tui.app import DvwApp
    from dvw_tui.screens.main import WorkspaceTree
    fake_client._workspaces[0].activity = record()
    fake_client._workspaces[1].activity = record()
    app = DvwApp(client=fake_client)
    async with app.run_test() as pilot:
        await pilot.pause(0.4)
        nodes = app.screen.query_one(WorkspaceTree).root.children
        assert 'would stop in 50m' in nodes[0].label.plain
        assert 'would stop' not in nodes[1].label.plain
        assert 'observation-only' in str(app.query_one('#inspect-body').content)
        # Keep the cached inspect response but refresh the workspace activity.
        fake_client._workspaces[0].activity = {**record(), 'state': 'active', 'reasons': ['cursor']}
        app.screen._render_inspect('alpha', app.screen._inspect_cache['alpha'])
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

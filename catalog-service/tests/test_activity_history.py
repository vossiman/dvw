from app.activity import ActivityObserver, ActivitySample
from app.activity_history import ActivityEvent, ActivityHistory
from app.models import Workspace
from tests.test_activity import sample, ws


def observer(tmp_path, **kw):
    history = ActivityHistory(tmp_path / 'activity-history.jsonl', **kw)
    return ActivityObserver(history=history), history


def tick(o, seconds, samples=None, workspace=None):
    o.update([workspace or ws()], samples if samples is not None else [sample()],
             now=seconds, wall=10000 + seconds)


def test_records_only_changes_not_every_sample(tmp_path):
    o, h = observer(tmp_path)
    for t in range(0, 121, 30):
        tick(o, t)
    events = h.tail()
    assert [(e.event, e.previous_state, e.state) for e in events] == [('change', None, 'idle')]
    assert events[0].at == 10000


def test_records_the_reset_and_the_reason_that_caused_it(tmp_path):
    o, h = observer(tmp_path)
    tick(o, 0)
    tick(o, 30)
    tick(o, 60, samples=[sample(complete=False, note='partial probe report')])
    tick(o, 90)
    events = h.tail()
    assert [e.event for e in events] == ['change', 'change', 'change']
    assert events[1].state == 'unknown' and events[1].note == 'partial probe report'
    assert events[2].state == 'idle' and events[2].idle_seconds == 0


def test_records_a_silent_reset_that_no_state_change_would_show(tmp_path):
    o, h = observer(tmp_path)
    tick(o, 0)
    tick(o, 30)
    tick(o, 60, samples=[sample(started_at='restarted')])
    events = h.tail()
    assert [e.event for e in events] == ['change', 'reset']
    assert events[1].state == 'idle' and events[1].idle_seconds == 0


def test_filters_by_workspace_and_limits(tmp_path):
    h = ActivityHistory(tmp_path / 'h.jsonl')
    for i in range(5):
        h.append(ActivityEvent(at=i, workspace_id='a' if i % 2 else 'b',
                               event='change', state='idle'))
    assert [e.at for e in h.tail(workspace_id='a')] == [1, 3]
    assert [e.at for e in h.tail(limit=2)] == [3, 4]


def test_rotates_once_and_still_reads_the_previous_file(tmp_path):
    h = ActivityHistory(tmp_path / 'h.jsonl', max_bytes=400)
    for i in range(40):
        h.append(ActivityEvent(at=i, workspace_id='w', event='change', state='idle'))
    assert (tmp_path / 'h.jsonl.1').exists()
    assert (tmp_path / 'h.jsonl').stat().st_size <= 400
    ats = [e.at for e in h.tail(limit=1000)]
    assert ats == sorted(ats) and ats[-1] == 39


def test_a_write_failure_never_stops_sampling(tmp_path):
    h = ActivityHistory(tmp_path / 'nodir' / 'h.jsonl')
    h.path.parent.write_text('not a directory')
    o = ActivityObserver(history=h)
    tick(o, 0)
    assert o.views([ws()], now=0)[0].state == 'idle'


def test_endpoint_serves_recorded_events(client, tmp_path):
    from app.deps import get_activity_observer

    o, h = observer(tmp_path)
    h.append(ActivityEvent(at=1.0, workspace_id='w', event='reset', state='idle',
                           note='partial probe report'))
    h.append(ActivityEvent(at=2.0, workspace_id='other', event='change', state='active'))
    client.app.dependency_overrides[get_activity_observer] = lambda: o

    rows = client.get('/v1/containers/activity/history').json()
    assert [r['workspace_id'] for r in rows] == ['w', 'other']
    assert rows[0]['note'] == 'partial probe report' and rows[0]['event'] == 'reset'

    only = client.get('/v1/containers/activity/history?workspace_id=w').json()
    assert [r['workspace_id'] for r in only] == ['w']


def test_endpoint_is_empty_when_recording_is_disabled(client):
    from app.deps import get_activity_observer

    client.app.dependency_overrides[get_activity_observer] = lambda: ActivityObserver()
    assert client.get('/v1/containers/activity/history').json() == []

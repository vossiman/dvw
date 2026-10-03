import asyncio

import pytest

from app.activity import ActivityObserver, ActivitySample
from app.models import Workspace
from app.stopper import Stopper, StopRefused, StopUncertain

IDLE = dict(tmux_sessions=0, terminals=0, cursor_connections=0,
            vscode_connections=0, agents=0, t3_servers=0)


def ws(**kw):
    return Workspace(id='w', repo='r', branch='main', **kw)


def sample(**kw):
    values = dict(workspace_id='w', container_id='c', started_at='start',
                  running=True, signals=dict(IDLE))
    values.update(kw)
    return ActivitySample(**values)


class FakeInspector:
    def __init__(self):
        self.recheck = [sample()]          # what activity_many returns
        self.stop_error = None             # exception to raise from stop_container
        self.state = ('exited', 'start')   # what container_state returns
        self.state_error = None
        self.stops = []
        self.fresh_calls = []
        self.forgotten = []
        self.on_recheck = None             # hook run inside activity_many

    def activity_many(self, ids, fresh=False):
        self.fresh_calls.append((tuple(ids), fresh))
        if self.on_recheck:
            self.on_recheck()
        return list(self.recheck)

    def stop_container(self, cid, grace):
        self.stops.append((cid, grace))
        if self.stop_error:
            raise self.stop_error

    def container_state(self, cid):
        if self.state_error:
            raise self.state_error
        return self.state

    def forget_snapshot(self, cid):
        self.forgotten.append(cid)


class Rig:
    def __init__(self, enforce=True, workspace=None, **stopper_kw):
        self.t = 0.0
        self.w = workspace or ws()
        self.observer = ActivityObserver(enforce=enforce)
        self.inspector = FakeInspector()
        self.invalidated = []
        self.stopper = Stopper(self.observer, self.inspector, enforce=enforce,
                               invalidate=self.invalidated.append,
                               clock=lambda: self.t, wall=lambda: 10000 + self.t,
                               **stopper_kw)

    def mature(self):
        for t in range(0, 3601, 30):
            self.t = float(t)
            self.observer.update([self.w], [sample()], now=self.t, wall=10000 + self.t)
        assert self.view().remaining_seconds == 0

    def view(self):
        return self.observer.views([self.w], now=self.t)[0]

    async def run(self):
        await self.stopper.run_pass([self.w])


async def test_matured_idle_workspace_is_stopped():
    r = Rig()
    r.mature()
    await r.run()
    assert r.inspector.stops == [('c', 10)]
    assert r.inspector.fresh_calls == [(('w',), True)]
    assert r.view().stop.result == 'stopped' and r.view().stop.idle_seconds == 3600
    assert r.invalidated == ['w'] and r.inspector.forgotten == ['c']


async def test_enforcement_off_never_stops():
    r = Rig(enforce=False)
    r.mature()
    await r.run()
    assert r.inspector.stops == [] and r.inspector.fresh_calls == []


async def test_not_yet_matured_is_left_alone():
    r = Rig()
    r.observer.update([r.w], [sample()], now=0, wall=10000)
    await r.run()
    assert r.inspector.stops == []


async def test_always_on_is_never_stopped():
    r = Rig(workspace=ws(always_on=True))
    for t in range(0, 3601, 30):
        r.t = float(t)
        r.observer.update([r.w], [sample()], now=r.t, wall=10000 + r.t)
    await r.run()
    assert r.inspector.stops == []


@pytest.mark.parametrize('recheck', [
    sample(signals={**IDLE, 'agents': 1}),            # activity
    sample(signals={**IDLE, 't3_servers': 1}),        # T3
    sample(signals={**IDLE, 'terminals': None}),      # a null signal
    sample(signals={}),                               # nothing measured
    sample(complete=False),                           # partial probe
    sample(container_id='other'),                     # different container
    sample(started_at='later'),                       # restarted
    ActivitySample('w', note='2 running containers'),  # siblings
    ActivitySample('w', running=False),               # already stopped
])
async def test_recheck_that_is_not_the_same_idle_blocks_the_stop(recheck):
    r = Rig()
    r.mature()
    r.inspector.recheck = [recheck]
    await r.run()
    assert r.inspector.stops == []


@pytest.mark.parametrize('recheck', [
    sample(signals={**IDLE, 'agents': 1}),
    sample(signals={**IDLE, 't3_servers': 1}),
])
async def test_activity_seen_by_the_recheck_costs_a_full_new_timeout(recheck):
    r = Rig()
    r.mature()
    r.inspector.recheck = [recheck]
    await r.run()
    r.inspector.recheck = [sample()]
    r.t += 30
    r.observer.update([r.w], [sample()], now=r.t, wall=10000 + r.t)
    assert r.view().remaining_seconds == 3600
    await r.run()
    assert r.inspector.stops == []


async def test_touch_during_recheck_cancels_the_stop():
    r = Rig()
    r.mature()
    r.inspector.on_recheck = lambda: r.observer.reset('w')   # a touch lands mid-recheck
    await r.run()
    assert r.inspector.stops == []
    assert r.view().remaining_seconds == 3600


async def test_recheck_of_one_workspace_leaves_others_alone():
    r = Rig()
    other = Workspace(id='o', repo='r', branch='main', idle_timeout_minutes=120)
    for t in range(0, 3601, 30):
        r.t = float(t)
        r.observer.update([r.w, other], [sample(), sample(workspace_id='o')],
                          now=r.t, wall=10000 + r.t)
    await r.stopper.run_pass([r.w, other])
    assert r.inspector.stops == [('c', 10)]          # w matured and was stopped
    still = r.observer.views([other], now=r.t)[0]
    assert still.state == 'idle' and still.idle_seconds == 3600


async def test_refused_stop_is_recorded_and_backs_off():
    r = Rig()
    r.mature()
    r.inspector.stop_error = StopRefused('docker: 500')
    await r.run()
    assert r.view().stop.result == 'failed'
    r.inspector.stop_error = None
    r.t += 30
    r.observer.update([r.w], [sample()], now=r.t, wall=10000 + r.t)
    await r.run()
    assert len(r.inspector.stops) == 1               # inside the 10 minute back-off
    for _ in range(20):                              # ten more minutes of idle passes
        r.t += 30
        r.observer.update([r.w], [sample()], now=r.t, wall=10000 + r.t)
    await r.run()
    assert len(r.inspector.stops) == 2


async def test_uncertain_stop_that_did_stop_is_reconciled_as_stopped():
    r = Rig()
    r.mature()
    r.inspector.stop_error = StopUncertain('timeout')
    r.inspector.state = ('exited', 'start')
    await r.run()
    assert r.view().stop is None                     # nothing assumed yet
    assert await r.stopper.wait('w', timeout=0.01) is True   # wait reconciles
    assert r.view().stop.result == 'stopped'


async def test_uncertain_stop_still_running_is_reconciled_as_failed():
    r = Rig()
    r.mature()
    r.inspector.stop_error = StopUncertain('timeout')
    r.inspector.state = ('running', 'start')
    await r.run()
    await r.run()                                    # next pass reconciles
    assert r.view().stop.result == 'failed'
    assert len(r.inspector.stops) == 1               # and backs off


async def test_uncertain_stop_then_restarted_container_counts_as_stopped():
    r = Rig()
    r.mature()
    r.inspector.stop_error = StopUncertain('timeout')
    r.inspector.state = ('running', 'a-later-start')
    await r.run()
    # What the next sample really shows after a restart: a new incarnation.
    r.inspector.recheck = [sample(started_at='a-later-start')]
    r.inspector.stop_error = None
    await r.run()
    assert r.view().stop.result == 'stopped'
    assert len(r.inspector.stops) == 1               # no second stop on old credit


async def test_uncertain_stop_of_a_removed_container_counts_as_stopped():
    r = Rig()
    r.mature()
    r.inspector.stop_error = StopUncertain('timeout')
    r.inspector.state = None
    await r.run()
    r.inspector.recheck = [ActivitySample('w', running=False)]
    await r.run()
    assert r.view().stop.result == 'stopped'
    assert len(r.inspector.stops) == 1


async def test_unreadable_target_keeps_the_stop_pending_and_blocks_another():
    r = Rig()
    r.mature()
    r.inspector.stop_error = StopUncertain('timeout')
    r.inspector.state_error = RuntimeError('docker down')
    await r.run()
    r.inspector.stop_error = None
    await r.run()
    await r.run()
    assert r.view().stop is None
    assert len(r.inspector.stops) == 1
    assert await r.stopper.wait('w', timeout=0.01) is False


async def test_wait_returns_at_once_when_nothing_is_pending():
    r = Rig()
    assert await r.stopper.wait('w', timeout=0.01) is True


async def test_touch_during_an_in_flight_stop_waits_for_it():
    r = Rig()
    r.mature()
    gate = asyncio.Event()
    loop = asyncio.get_running_loop()
    order = []

    def slow_stop(cid, grace):
        order.append('stop-start')
        asyncio.run_coroutine_threadsafe(gate.wait(), loop).result(5)
        order.append('stop-end')
    r.inspector.stop_container = slow_stop

    run = asyncio.create_task(r.run())
    while 'stop-start' not in order:
        await asyncio.sleep(0.01)
    waiter = asyncio.create_task(r.stopper.wait('w', timeout=5))
    await asyncio.sleep(0.05)
    assert not waiter.done()                         # still waiting on the stop
    gate.set()
    assert await waiter is True
    await run
    assert order == ['stop-start', 'stop-end']


async def test_cancelled_mid_stop_leaves_no_record():
    r = Rig()
    r.mature()
    started = asyncio.Event()
    loop = asyncio.get_running_loop()
    release = asyncio.Event()

    def slow_stop(cid, grace):
        loop.call_soon_threadsafe(started.set)
        asyncio.run_coroutine_threadsafe(release.wait(), loop).result(5)
    r.inspector.stop_container = slow_stop
    run = asyncio.create_task(r.run())
    await started.wait()
    run.cancel()
    with pytest.raises(asyncio.CancelledError):
        await run
    release.set()
    assert r.view().stop is None


async def test_wait_uses_the_configured_timeout_and_gives_up():
    r = Rig(wait_timeout=0.05)
    r.mature()
    started = asyncio.Event()
    loop = asyncio.get_running_loop()
    release = asyncio.Event()

    def never_returns(cid, grace):
        loop.call_soon_threadsafe(started.set)
        asyncio.run_coroutine_threadsafe(release.wait(), loop).result(5)
    r.inspector.stop_container = never_returns
    run = asyncio.create_task(r.run())
    await started.wait()
    assert await r.stopper.wait('w') is False        # no explicit timeout
    release.set()
    await run


async def test_workspace_removed_from_the_catalog_is_not_stopped():
    r = Rig(still_listed=lambda ws_id: False)
    r.mature()
    await r.run()
    assert r.inspector.stops == []
    assert r.view().stop is None

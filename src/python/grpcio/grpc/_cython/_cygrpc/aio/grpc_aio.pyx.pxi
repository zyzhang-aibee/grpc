# Copyright 2019 gRPC authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

import enum

cdef str _GRPC_ASYNCIO_ENGINE = os.environ.get('GRPC_ASYNCIO_ENGINE', 'default').upper()
cdef _AioState _global_aio_state = _AioState()


class AsyncIOEngine(enum.Enum):
    DEFAULT = 'default'
    CUSTOM_IO_MANAGER = 'custom_io_manager'
    POLLER = 'poller'


cdef _default_asyncio_engine():
    return AsyncIOEngine.CUSTOM_IO_MANAGER


cdef grpc_completion_queue *global_completion_queue():
    return _global_aio_state.cq.c_ptr()


cdef class _AioState:

    def __cinit__(self):
        self.lock = threading.RLock()
        self.refcount = 0
        self.engine = None
        self.cq = None


cdef _initialize_custom_io_manager():
    # Activates asyncio IO manager.
    # NOTE(lidiz) Custom IO manager must be activated before the first
    # `grpc_init()`. Otherwise, some special configurations in Core won't
    # pick up the change, and resulted in SEGFAULT or ABORT.
    install_asyncio_iomgr()

    # Initializes gRPC Core, must be called before other Core API
    grpc_init()

    # Timers are triggered by the Asyncio loop. We disable
    # the background thread that is being used by the native
    # gRPC iomgr.
    grpc_timer_manager_set_threading(False)

    # gRPC callbaks are executed within the same thread used by the Asyncio
    # event loop, as it is being done by the other Asyncio callbacks.
    Executor.SetThreadingAll(False)

    # Creates the only completion queue
    _global_aio_state.cq = CallbackCompletionQueue()


cdef _initialize_poller():
    # Initializes gRPC Core, must be called before other Core API
    grpc_init()

    # Creates the only completion queue
    _global_aio_state.cq = PollerCompletionQueue()


cdef _actual_aio_initialization():
    # Picks the engine for gRPC AsyncIO Stack
    _global_aio_state.engine = AsyncIOEngine.__members__.get(
        _GRPC_ASYNCIO_ENGINE,
        AsyncIOEngine.DEFAULT,
    )
    if _global_aio_state.engine is AsyncIOEngine.DEFAULT:
        _global_aio_state.engine = _default_asyncio_engine()
    _LOGGER.info('Using %s as I/O engine', _global_aio_state.engine)

    # Initializes the process-level state accordingly
    if _global_aio_state.engine is AsyncIOEngine.CUSTOM_IO_MANAGER:
        _initialize_custom_io_manager()
    elif _global_aio_state.engine is AsyncIOEngine.POLLER:
        _initialize_poller()
    else:
        raise ValueError('Unsupported engine type [%s]' % _global_aio_state.engine)


def _grpc_shutdown_wrapper(_):
    """A thin Python wrapper of Core's shutdown function.

    Define functions are not allowed in "cdef" functions, and Cython complains
    about a simple lambda with a C function.
    """
    grpc_shutdown_blocking()


cdef _actual_aio_shutdown():
    if _global_aio_state.engine is AsyncIOEngine.CUSTOM_IO_MANAGER:
        future = schedule_coro_threadsafe(
            _global_aio_state.cq.shutdown(),
            (<CallbackCompletionQueue>_global_aio_state.cq)._loop
        )
        future.add_done_callback(_grpc_shutdown_wrapper)
    elif _global_aio_state.engine is AsyncIOEngine.POLLER:
        _global_aio_state.cq.shutdown()
        grpc_shutdown_blocking()
    else:
        raise ValueError('Unsupported engine type [%s]' % _global_aio_state.engine)


cpdef init_grpc_aio():
    """Initializes the gRPC AsyncIO module.

    Expected to be invoked on critical class constructors.
    E.g., AioChannel, AioServer.
    """
    with _global_aio_state.lock:
        _global_aio_state.refcount += 1
        if _global_aio_state.refcount == 1:
            _actual_aio_initialization()


cpdef shutdown_grpc_aio():
    """Shuts down the gRPC AsyncIO module.

    Expected to be invoked on critical class destructors.
    E.g., AioChannel, AioServer.
    """
    with _global_aio_state.lock:
        assert _global_aio_state.refcount > 0
        _global_aio_state.refcount -= 1
        if not _global_aio_state.refcount:
            _actual_aio_shutdown()

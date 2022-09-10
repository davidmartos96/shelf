// Copyright 2019 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

@TestOn('vm')
import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';
import 'package:test/test.dart';

void main() {
  // Create a server that listens on localhost for testing
  late io.IOServer server;

  setUp(() async {
    try {
      server = await io.IOServer.bind(InternetAddress.loopbackIPv6, 0);
    } on SocketException catch (_) {
      server = await io.IOServer.bind(InternetAddress.loopbackIPv4, 0);
    }
  });

  tearDown(() => server.close());

  Future<String> get(String path) =>
      http.read(Uri.parse(server.url.toString() + path));
  Future<int> head(String path) async =>
      (await http.head(Uri.parse(server.url.toString() + path))).statusCode;

  test('get sync/async handler', () async {
    var app = Router();

    app.get('/sync-hello', (Request request) {
      return Response.ok('hello-world');
    });

    app.get('/async-hello', (Request request) async {
      return Future.microtask(() {
        return Response.ok('hello-world');
      });
    });

    // check that catch-alls work
    app.all('/<path|[^]*>', (Request request) {
      return Response.ok('not-found');
    });

    server.mount(app);

    expect(await get('/sync-hello'), 'hello-world');
    expect(await get('/async-hello'), 'hello-world');
    expect(await get('/wrong-path'), 'not-found');

    expect(await head('/sync-hello'), 200);
    expect(await head('/async-hello'), 200);
    expect(await head('/wrong-path'), 200);
  });

  test('params', () async {
    var app = Router();

    app.get(r'/user/<user>/groups/<group|\d+>', (Request request) {
      final user = request.params['user'];
      final group = request.params['group'];
      return Response.ok('$user / $group');
    });

    server.mount(app);

    expect(await get('/user/jonasfj/groups/42'), 'jonasfj / 42');
  });

  test('params by arguments', () async {
    var app = Router();

    app.get(r'/user/<user>/groups/<group|\d+>',
        (Request request, String user, String group) {
      return Response.ok('$user / $group');
    });

    server.mount(app);

    expect(await get('/user/jonasfj/groups/42'), 'jonasfj / 42');
  });

  test('mount(Router)', () async {
    var api = Router();
    api.get('/user/<user>/info', (Request request, String user) {
      return Response.ok('Hello $user');
    });

    var app = Router();
    app.get('/hello', (Request request) {
      return Response.ok('hello-world');
    });

    app.mount('/api/', api);

    app.all('/<_|[^]*>', (Request request) {
      return Response.ok('catch-all-handler');
    });

    server.mount(app);

    expect(await get('/hello'), 'hello-world');
    expect(await get('/api/user/jonasfj/info'), 'Hello jonasfj');
    expect(await get('/api/user/jonasfj/info-wrong'), 'catch-all-handler');
  });

  test('mount(Handler) with middleware', () async {
    var api = Router();
    api.get('/hello', (Request request) {
      return Response.ok('Hello');
    });

    final middleware = createMiddleware(
      requestHandler: (request) {
        if (request.url.queryParameters.containsKey('ok')) {
          return Response.ok('middleware');
        }
        return null;
      },
    );

    var app = Router();
    app.mount(
      '/api/',
      Pipeline().addMiddleware(middleware).addHandler(api),
    );

    server.mount(app);

    expect(await get('/api/hello'), 'Hello');
    expect(await get('/api/hello?ok'), 'middleware');
  });

  test('mount(Router) does not require a trailing slash', () async {
    var api = Router();
    api.get('/', (Request request) {
      return Response.ok('Hello World!');
    });

    api.get('/user/<user>/info', (Request request, String user) {
      return Response.ok('Hello $user');
    });

    var app = Router();
    app.get('/hello', (Request request) {
      return Response.ok('hello-world');
    });

    app.mount('/api', api);

    app.all('/<_|[^]*>', (Request request) {
      return Response.ok('catch-all-handler');
    });

    server.mount(app);

    expect(await get('/hello'), 'hello-world');
    expect(await get('/api'), 'Hello World!');
    expect(await get('/api/'), 'Hello World!');
    expect(await get('/api/user/jonasfj/info'), 'Hello jonasfj');
    expect(await get('/api/user/jonasfj/info-wrong'), 'catch-all-handler');
  });

  test('responds with 404 if no handler matches', () {
    var api = Router()..get('/hello', (request) => Response.ok('Hello'));
    server.mount(api);

    expect(
        get('/hi'),
        throwsA(isA<http.ClientException>()
            .having((e) => e.message, 'message', contains('404: Not Found.'))));
  });

  test('can invoke custom handler if no route matches', () {
    var api = Router(notFoundHandler: (req) => Response.ok('Not found, but ok'))
      ..get('/hello', (request) => Response.ok('Hello'));
    server.mount(api);

    expect(get('/hi'), completion('Not found, but ok'));
  });

  test('can call Router.routeNotFound.read multiple times', () async {
    final b1 = await Router.routeNotFound.readAsString();
    expect(b1, 'Route not found');
    final b2 = await Router.routeNotFound.readAsString();
    expect(b2, b1);
  });

  test('can mount dynamic routes', () async {
    // routes for an [user] to [other]. This gets nested
    // parameters from previous mounts
    Handler createUserToOtherHandler(String user, String other) {
      var router = Router();

      router.get('/<action>', (Request request, String action) {
        return Response.ok('$user to $other: $action');
      });

      return router;
    }

    // routes for a specific [user]. The user value
    // is extracted from the mount
    Handler createUserHandler(String user) {
      var router = Router();

      router.mount('/to/<other>/', (Request request, String other) {
        final handler = createUserToOtherHandler(user, other);
        return handler(request);
      });

      router.get('/self', (Request request) {
        return Response.ok("I'm $user");
      });

      router.get('/', (Request request) {
        return Response.ok('$user root');
      });
      return router;
    }

    var app = Router();
    app.get('/hello', (Request request) {
      return Response.ok('hello-world');
    });

    app.mount('/users/<user>', (Request request, String user) {
      final handler = createUserHandler(user);
      return handler(request);
    });

    app.all('/<_|[^]*>', (Request request) {
      return Response.ok('catch-all-handler');
    });

    server.mount(app);

    expect(await get('/hello'), 'hello-world');
    expect(await get('/users/david/to/jake/salutes'), 'david to jake: salutes');
    expect(await get('/users/jennifer/to/mary/bye'), 'jennifer to mary: bye');
    expect(await get('/users/jennifer/self'), "I'm jennifer");
    expect(await get('/users/jake'), 'jake root');
    expect(await get('/users/david/no-route'), 'catch-all-handler');
  });

  test('can mount dynamic routes with regexp', () async {
    var app = Router();

    app.mount(r'/before/<bookId|\d+>/after', (Request request, String bookId) {
      var router = Router();
      router.get('/', (r) => Response.ok('book ${int.parse(bookId)}'));
      return router(request);
    });

    app.all('/<_|[^]*>', (Request request) {
      return Response.ok('catch-all-handler');
    });

    server.mount(app);

    expect(await get('/before/123/after'), 'book 123');
    expect(await get('/before/abc/after'), 'catch-all-handler');
  });
}

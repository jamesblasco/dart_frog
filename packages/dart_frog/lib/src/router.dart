// Copyright 2019 Google LLC
// Copyright 2022 Very Good Ventures
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
//
// Original Source: https://github.com/dart-lang/shelf/blob/master/pkgs/shelf_router/lib/src/router.dart
// Modified: For interoperability with package:dart_frog

part of '_internal.dart';

/// Middleware to remove body from request.
Handler _removeBody(Handler handler) {
  return (context) async {
    var response = await handler(context);
    if (response.headers.containsKey('content-length')) {
      response = response.copyWith(headers: {'content-length': '0'});
    }
    return response.copyWith(body: <int>[]);
  };
}

/// A class that routes requests to handlers based on HTTP verb and route
/// pattern.
class Router {
  /// Creates a new [Router] routing requests to handlers.
  ///
  /// The [notFoundHandler] will be invoked for requests where no matching route
  /// was found. By default, a simple 404 response will be used.
  Router({Handler notFoundHandler = _defaultNotFound})
      : _notFoundHandler = notFoundHandler;

  final List<RouterEntry> _routes = [];
  final Handler _notFoundHandler;

  /// Add [handler] for [verb] requests to [route].
  ///
  /// If [verb] is `GET` the [handler] will also be called for `HEAD` requests
  /// matching [route]. This is because handling `GET` requests without handling
  /// `HEAD` is always wrong. To explicitely implement a `HEAD` handler it must
  /// be registered before the `GET` handler.
  void add(String verb, String route, Function handler) {
    if (!isHttpMethod(verb)) {
      throw ArgumentError.value(verb, 'verb', 'expected a valid HTTP method');
    }

    final _verb = verb.toUpperCase();

    if (_verb == 'GET') {
      // Handling in a 'GET' request without handling a 'HEAD' request is always
      // wrong, thus, we add a default implementation that discards the body.
      _routes.add(RouterEntry('HEAD', route, handler, middleware: _removeBody));
    }
    _routes.add(RouterEntry(_verb, route, handler));
  }

  /// Handle all request to [route] using [handler].
  void all(String route, Function handler) {
    _all(route, handler, mounted: false);
  }

  void _all(String route, Function handler, {required bool mounted}) {
    _routes.add(RouterEntry('ALL', route, handler, mounted: mounted));
  }

  /// Mount a handler below a prefix.
  void mount(String prefix, Function handler) {
    if (!prefix.startsWith('/')) {
      throw ArgumentError.value(prefix, 'prefix', 'must start with a slash');
    }

    // The first slash is always in request.handlerPath
    final path = prefix.substring(1);

    // Prefix it with two underscores to avoid conflicts
    // with user defined path parameters
    const pathParam = '__path';

    if (prefix.endsWith('/')) {
      _all(
        '$prefix<$pathParam|[^]*>',
        (RequestContext context, RouterEntry route) {
          // Remove path param from extracted route params
          final params = [...route.params]..removeLast();
          return _invokeMountedHandler(context, handler, path, params);
        },
        mounted: true,
      );
    } else {
      _all(
        prefix,
        (RequestContext context, RouterEntry route) {
          return _invokeMountedHandler(
            context,
            handler,
            path,
            route.params,
          );
        },
        mounted: true,
      );
      _all(
        '$prefix/<$pathParam|[^]*>',
        (RequestContext context, RouterEntry route) {
          // Remove path param from extracted route params
          final params = [...route.params]..removeLast();
          return _invokeMountedHandler(context, handler, '$path/', params);
        },
        mounted: true,
      );
    }
  }

  Future<Response> _invokeMountedHandler(
    RequestContext context,
    Function handler,
    String path,
    List<ParamInfo> paramInfos,
  ) async {
    final params = _getParamsFromRequest(context.request);
    final resolvedPath =
        _replaceParamsInPath(context.request, path, params, paramInfos);

    return await Function.apply(handler, [
      RequestContext._(context.request._request.change(path: resolvedPath)),
      ...paramInfos.map((info) => params[info.name]),
    ]) as Response;
  }

  Map<String, String> _getParamsFromRequest(Request request) {
    // ignore: cast_nullable_to_non_nullable
    return request._request.context['shelf_router/params']
        as Map<String, String>;
  }

  /// Replaces the variable slots (<someVar>) from [path] with the
  /// values from [params]
  String _replaceParamsInPath(
    Request request,
    String path,
    Map<String, String> params,
    List<ParamInfo> paramInfos,
  ) {
    // we iterate the non-resolved path and we write to a StringBuffer
    // resolving ther parameters along the way
    final resolvedPathBuff = StringBuffer();
    var paramIndex = 0;
    var charIndex = 0;
    while (charIndex < path.length) {
      if (paramIndex < paramInfos.length) {
        final paramInfo = paramInfos[paramIndex];
        if (charIndex < paramInfo.startIdx - 1) {
          // Add up until the param slot starts
          final part = path.substring(charIndex, paramInfo.startIdx - 1);
          resolvedPathBuff.write(part);
          charIndex += part.length;
        } else {
          // Add the resolved value of the parameter
          final paramName = paramInfo.name;
          final paramValue = params[paramName]!;
          resolvedPathBuff.write(paramValue);
          charIndex = paramInfo.endIdx - 1;
          paramIndex++;
        }
      } else {
        // All params looped, so add up until the end of the path
        final part = path.substring(charIndex, path.length);
        resolvedPathBuff.write(part);
        charIndex += part.length;
      }
    }
    return resolvedPathBuff.toString();
  }

  /// Route incoming requests to registered handlers.
  ///
  /// This method allows a Router instance to be a [Handler].
  Future<Response> call(RequestContext context) async {
    for (final route in _routes) {
      if (route.verb != context.request.method.value.toUpperCase() &&
          route.verb != 'ALL') {
        continue;
      }
      final params = route.match('/${context.request._request.url.path}');
      if (params != null) {
        final response = await route.invoke(context, params);
        if (response != routeNotFound) {
          return response;
        }
      }
    }
    return _notFoundHandler(context);
  }

  // Handlers for all methods

  /// Handle `GET` request to [route] using [handler].
  ///
  /// If no matching handler for `HEAD` requests is registered, such requests
  /// will also be routed to the [handler] registered here.
  void get(String route, Function handler) => add('GET', route, handler);

  /// Handle `HEAD` request to [route] using [handler].
  void head(String route, Function handler) => add('HEAD', route, handler);

  /// Handle `POST` request to [route] using [handler].
  void post(String route, Function handler) => add('POST', route, handler);

  /// Handle `PUT` request to [route] using [handler].
  void put(String route, Function handler) => add('PUT', route, handler);

  /// Handle `DELETE` request to [route] using [handler].
  void delete(String route, Function handler) => add('DELETE', route, handler);

  /// Handle `OPTIONS` request to [route] using [handler].
  void options(String route, Function handler) =>
      add('OPTIONS', route, handler);

  /// Handle `PATCH` request to [route] using [handler].
  void patch(String route, Function handler) => add('PATCH', route, handler);

  static Response _defaultNotFound(RequestContext context) => routeNotFound;

  /// Sentinel [Response] object indicating that no matching route was found.
  ///
  /// This is the default response value from a [Router] created without a
  /// `notFoundHandler`, when no routes matches the incoming request.
  static final Response routeNotFound = _RouteNotFoundResponse();
}

/// Extends [Response] to allow it to be used multiple times in the
/// actual content being served.
class _RouteNotFoundResponse extends Response {
  _RouteNotFoundResponse()
      : super(statusCode: HttpStatus.notFound, body: _message);
  static const _message = 'Route not found';
  static final _messageBytes = utf8.encode(_message);

  @override
  shelf.Response get _response => super._response.change(body: _messageBytes);

  @override
  Stream<List<int>> bytes() => Stream<List<int>>.value(_messageBytes);

  @override
  Future<String> body() async => _message;

  @override
  Response copyWith({Map<String, Object?>? headers, dynamic body}) {
    return super.copyWith(headers: headers, body: body ?? _message);
  }
}

/// Check if the [regexp] is non-capturing.
bool _isNoCapture(String regexp) {
  // Construct a new regular expression matching anything containing regexp,
  // then match with empty-string and count number of groups.
  return RegExp('^(?:$regexp)|.*\$').firstMatch('')!.groupCount == 0;
}

/// {@template router_entry}
/// Entry in the router.
///
/// This class implements the logic for matching the path pattern.
/// {@endtemplate}
class RouterEntry {
  /// {@macro router_entry}
  factory RouterEntry(
    String verb,
    String route,
    Function handler, {
    Middleware? middleware,
    bool mounted = false,
  }) {
    middleware = middleware ?? ((Handler fn) => fn);

    if (!route.startsWith('/')) {
      throw ArgumentError.value(
        route,
        'route',
        'expected route to start with a slash',
      );
    }

    final params = <ParamInfo>[];
    var pattern = '';
    // Keep the index where the matches are located
    // so that we can calculate the positioning of
    // the extracted parameter
    var prevMatchIndex = 0;
    for (final m in _parser.allMatches(route)) {
      final firstGroup = m[1]!;
      // ignore: use_string_buffers
      pattern += RegExp.escape(firstGroup);
      if (m[2] != null) {
        final paramName = m[2]!;
        final startIdx = prevMatchIndex + firstGroup.length;
        final paramInfo = ParamInfo(
          name: paramName,
          startIdx: startIdx,
          endIdx: m.end,
        );
        params.add(paramInfo);
        prevMatchIndex = m.end;
        if (m[3] != null && !_isNoCapture(m[3]!)) {
          throw ArgumentError.value(
            route,
            'route',
            'expression for "${m[2]}" is capturing',
          );
        }
        pattern += '(${m[3] ?? '[^/]+'})';
      }
    }
    final routePattern = RegExp('^$pattern\$');

    return RouterEntry._(
      verb,
      route,
      handler,
      middleware,
      routePattern,
      params,
      mounted,
    );
  }

  RouterEntry._(
    this.verb,
    this.route,
    this._handler,
    this._middleware,
    this._routePattern,
    this._params,
    this._mounted,
  );

  /// Pattern for parsing the route pattern
  static final RegExp _parser = RegExp(r'([^<]*)(?:<([^>|]+)(?:\|([^>]*))?>)?');

  /// The route entry verb and route.
  final String verb, route;
  final Function _handler;
  final Middleware _middleware;

  /// Indicates this entry is used as a mounting point.
  final bool _mounted;

  /// Expression that the request path must match.
  ///
  /// This also captures any parameters in the route pattern.
  final RegExp _routePattern;

  final List<ParamInfo> _params;

  /// Names for the parameters in the route pattern.
  List<ParamInfo> get params => _params.toList();

  /// Returns a map from parameter name to value, if the path matches the
  /// route pattern. Otherwise returns null.
  Map<String, String>? match(String path) {
    // Check if path matches the route pattern
    final m = _routePattern.firstMatch(path);
    if (m == null) return null;
    // Construct map from parameter name to matched value
    final params = <String, String>{};
    for (var i = 0; i < _params.length; i++) {
      final param = _params[i];
      // first group is always the full match, we ignore this group.
      params[param.name] = m[i + 1]!;
    }
    return params;
  }

  /// Invoke handler with given context and params.
  Future<Response> invoke(
    RequestContext context,
    Map<String, String> params,
  ) async {
    final request = context.request._request.change(
      context: {'shelf_router/params': params},
    );
    final _context = RequestContext._(request);

    return await _middleware((request) async {
      if (_mounted) {
        // if this route is mounted, we include
        // the route itself as a parameter so
        // that the mount can extract the parameters
        // ignore: avoid_dynamic_calls
        return await _handler(_context, this) as Response;
      }

      if (_handler is Handler || _params.isEmpty) {
        // ignore: avoid_dynamic_calls
        return await _handler(_context) as Response;
      }

      final dynamic result = await Function.apply(_handler, <dynamic>[
        _context,
        ..._params.map((param) => params[param.name]),
      ]);
      return result as Response;
    })(_context);
  }
}

/// {@template param_info}
/// This class holds information about a parameter extracted
/// from the route path.
/// The indexes can by used by the mount logic to resolve the
/// parametrized path when handling the request.
/// {@endtemplate}
class ParamInfo {
  /// {@macro param_info}
  const ParamInfo({
    required this.name,
    required this.startIdx,
    required this.endIdx,
  });

  /// This is the name of the parameter, without <, >
  final String name;

  /// The index in the route String where the parameter
  /// expression starts (inclusive)
  final int startIdx;

  /// The index in the route String where the parameter
  /// expression ends (exclusive)
  final int endIdx;
}

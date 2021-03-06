// Copyright (c) 2020, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// Helpers for working with the output of `--trace-precompiler-to` VM flag.
library vm_snapshot_analysis.precompiler_trace;

import 'dart:io';
import 'dart:math' as math;

import 'package:vm_snapshot_analysis/name.dart';
import 'package:vm_snapshot_analysis/program_info.dart';
import 'package:vm_snapshot_analysis/utils.dart';

/// Build [CallGraph] based on the trace written by `--trace-precompiler-to`
/// flag.
Future<CallGraph> loadTrace(File input) async =>
    _TraceReader(await loadJson(input)).readTrace();

/// [CallGraphNode] represents a node of the call-graph. It can either be:
///
///   - a function, in which case [data] will be [ProgramInfoNode] of type
///     [NodeType.functionNode];
///   - a dynamic call node, in which case [data] will be a [String] selector;
///   - a dispatch table call node, in which case [data] will be an [int]
///     selector id.
///
class CallGraphNode {
  /// An index of this node in [CallGraph.nodes].
  final int id;

  /// Successors of this node.
  final List<CallGraphNode> succ = [];

  /// Predecessors of this node.
  final List<CallGraphNode> pred = [];

  /// Datum associated with this node: a [ProgramInfoNode] (function),
  /// a [String] (dynamic call selector) or an [int] (dispatch table
  /// selector id).
  final data;

  /// Preorder number of this node.
  ///
  /// Computed by [CallGraph.computeDominators].
  int _preorderNumber;

  /// Dominator of this node.
  ///
  /// Computed by [CallGraph.computeDominators].
  CallGraphNode dominator;

  /// Nodes dominated by this node.
  ///
  /// Computed by [CallGraph.computeDominators].
  List<CallGraphNode> dominated = _emptyNodeList;

  CallGraphNode(this.id, {this.data});

  bool get isFunctionNode =>
      data is ProgramInfoNode && data.type == NodeType.functionNode;

  bool get isClassNode =>
      data is ProgramInfoNode && data.type == NodeType.classNode;

  bool get isDynamicCallNode => data is String;

  /// Create outgoing edge from this node to the given node [n].
  void connectTo(CallGraphNode n) {
    if (n == this) {
      return;
    }

    if (!succ.contains(n)) {
      n.pred.add(this);
      succ.add(n);
    }
  }

  void _addDominatedBlock(CallGraphNode n) {
    if (identical(dominated, _emptyNodeList)) {
      dominated = [];
    }
    dominated.add(n);
    n.dominator = this;
  }

  void visitDominatorTree(bool Function(CallGraphNode n, int depth) callback,
      [int depth = 0]) {
    if (callback(this, depth)) {
      for (var n in dominated) {
        n.visitDominatorTree(callback, depth + 1);
      }
    }
  }

  @override
  String toString() {
    return 'CallGraphNode(${data is ProgramInfoNode ? data.qualifiedName : data})';
  }
}

const _emptyNodeList = <CallGraphNode>[];

class CallGraph {
  final ProgramInfo program;
  final List<CallGraphNode> nodes;

  // Mapping from [ProgramInfoNode] to a corresponding [CallGraphNode] (if any)
  // via [ProgramInfoNode.id].
  final List<CallGraphNode> _nodeByEntityId;

  CallGraph._(this.program, this.nodes, this._nodeByEntityId);

  CallGraphNode get root => nodes.first;

  CallGraphNode lookup(ProgramInfoNode node) => _nodeByEntityId[node.id];

  Iterable<CallGraphNode> get dynamicCalls =>
      nodes.where((n) => n.isDynamicCallNode);

  /// Compute a collapsed version of the call-graph, where
  CallGraph collapse(NodeType type, {bool dropCallNodes = false}) {
    final nodesByData = <Object, CallGraphNode>{};
    final nodeByEntityId = <CallGraphNode>[];

    ProgramInfoNode collapsed(ProgramInfoNode nn) {
      var n = nn;
      while (n.parent != null && n.type != type) {
        n = n.parent;
      }
      return n;
    }

    CallGraphNode nodeFor(Object data) {
      return nodesByData.putIfAbsent(data, () {
        final n = CallGraphNode(nodesByData.length, data: data);
        if (data is ProgramInfoNode) {
          if (nodeByEntityId.length <= data.id) {
            nodeByEntityId.length = data.id * 2 + 1;
          }
          nodeByEntityId[data.id] = n;
        }
        return n;
      });
    }

    final newNodes = nodes.map((n) {
      if (n.data is ProgramInfoNode) {
        return nodeFor(collapsed(n.data));
      } else if (!dropCallNodes) {
        return nodeFor(n.data);
      }
    }).toList(growable: false);

    for (var n in nodes) {
      for (var succ in n.succ) {
        final from = newNodes[n.id];
        final to = newNodes[succ.id];

        if (from != null && to != null) {
          from.connectTo(to);
        }
      }
    }

    return CallGraph._(
        program, nodesByData.values.toList(growable: false), nodeByEntityId);
  }

  /// Compute dominator tree of the call-graph.
  ///
  /// The code for dominator tree computation is taken verbatim from the
  /// native compiler (see runtime/vm/compiler/backend/flow_graph.cc).
  void computeDominators() {
    final size = nodes.length;

    // Compute preorder numbering for the graph using DFS.
    final parent = List<int>.filled(size, -1);
    final preorder = List<CallGraphNode>.filled(size, null);

    var N = 0;
    void dfs() {
      final stack = [_DfsState(p: -1, n: nodes.first)];
      while (stack.isNotEmpty) {
        final s = stack.removeLast();
        final p = s.p;
        final n = s.n;
        if (n._preorderNumber == null) {
          n._preorderNumber = N;
          preorder[n._preorderNumber] = n;
          parent[n._preorderNumber] = p;

          for (var w in n.succ) {
            stack.add(_DfsState(p: n._preorderNumber, n: w));
          }

          N++;
        }
      }
    }

    dfs();

    for (var node in nodes) {
      if (node._preorderNumber == null) {
        print('${node} is unreachable');
      }
    }

    // Use the SEMI-NCA algorithm to compute dominators.  This is a two-pass
    // version of the Lengauer-Tarjan algorithm (LT is normally three passes)
    // that eliminates a pass by using nearest-common ancestor (NCA) to
    // compute immediate dominators from semidominators.  It also removes a
    // level of indirection in the link-eval forest data structure.
    //
    // The algorithm is described in Georgiadis, Tarjan, and Werneck's
    // "Finding Dominators in Practice".
    // See http://www.cs.princeton.edu/~rwerneck/dominators/ .

    // All arrays are maps between preorder basic-block numbers.
    final idom = parent.toList(); // Immediate dominator.
    final semi = List<int>.generate(size, (i) => i); // Semidominator.
    final label =
        List<int>.generate(size, (i) => i); // Label for link-eval forest.

    void compressPath(int start, int current) {
      final next = parent[current];
      if (next > start) {
        compressPath(start, next);
        label[current] = math.min(label[current], label[next]);
        parent[current] = parent[next];
      }
    }

    // 1. First pass: compute semidominators as in Lengauer-Tarjan.
    // Semidominators are computed from a depth-first spanning tree and are an
    // approximation of immediate dominators.

    // Use a link-eval data structure with path compression.  Implement path
    // compression in place by mutating the parent array.  Each block has a
    // label, which is the minimum block number on the compressed path.

    // Loop over the blocks in reverse preorder (not including the graph
    // entry).
    for (var block_index = size - 1; block_index >= 1; --block_index) {
      // Loop over the predecessors.
      final block = preorder[block_index];
      // Clear the immediately dominated blocks in case ComputeDominators is
      // used to recompute them.
      for (final pred in block.pred) {
        // Look for the semidominator by ascending the semidominator path
        // starting from pred.
        final pred_index = pred._preorderNumber;
        var best = pred_index;
        if (pred_index > block_index) {
          compressPath(block_index, pred_index);
          best = label[pred_index];
        }

        // Update the semidominator if we've found a better one.
        semi[block_index] = math.min(semi[block_index], semi[best]);
      }

      // Now use label for the semidominator.
      label[block_index] = semi[block_index];
    }

    // 2. Compute the immediate dominators as the nearest common ancestor of
    // spanning tree parent and semidominator, for all blocks except the entry.
    for (var block_index = 1; block_index < size; ++block_index) {
      var dom_index = idom[block_index];
      while (dom_index > semi[block_index]) {
        dom_index = idom[dom_index];
      }
      idom[block_index] = dom_index;
      preorder[dom_index]._addDominatedBlock(preorder[block_index]);
    }
  }
}

class _DfsState {
  final int p;
  final CallGraphNode n;
  _DfsState({this.p, this.n});
}

/// Helper class for reading `--trace-precompiler-to` output.
///
/// See README.md for description of the format.
class _TraceReader {
  final List<Object> trace;
  final List<Object> strings;
  final List<Object> entities;

  final program = ProgramInfo();

  /// Mapping between entity ids and corresponding [ProgramInfoNode] nodes.
  final entityById = List<ProgramInfoNode>.filled(1024, null, growable: true);

  /// Mapping between functions (represented as [ProgramInfoNode]s) and
  /// their selector ids.
  final selectorIdMap = <ProgramInfoNode, int>{};

  /// Set of functions which can be reached through dynamic dispatch.
  final dynamicFunctions = Set<ProgramInfoNode>();

  _TraceReader(Map<String, dynamic> data)
      : strings = data['strings'],
        entities = data['entities'],
        trace = data['trace'];

  /// Read all trace events and construct the call graph based on them.
  CallGraph readTrace() {
    var pos = 0; // Position in the [trace] array.
    CallGraphNode currentNode;

    final nodes = <CallGraphNode>[];
    final nodeByEntityId = <CallGraphNode>[];
    final callNodesBySelector = <dynamic, CallGraphNode>{};
    final allocated = Set<ProgramInfoNode>();

    Object next() => trace[pos++];

    CallGraphNode makeNode({dynamic data}) {
      final n = CallGraphNode(nodes.length, data: data);
      nodes.add(n);
      return n;
    }

    CallGraphNode makeCallNode(dynamic selector) => callNodesBySelector
        .putIfAbsent(selector, () => makeNode(data: selector));

    CallGraphNode nodeFor(ProgramInfoNode n) {
      if (nodeByEntityId.length <= n.id) {
        nodeByEntityId.length = n.id * 2 + 1;
      }
      return nodeByEntityId[n.id] ??= makeNode(data: n);
    }

    void recordDynamicCall(String selector) {
      currentNode.connectTo(makeCallNode(selector));
    }

    void recordInterfaceCall(int selector) {
      currentNode.connectTo(makeCallNode(selector));
    }

    void recordStaticCall(ProgramInfoNode to) {
      currentNode.connectTo(nodeFor(to));
    }

    void recordFieldRef(ProgramInfoNode field) {
      currentNode.connectTo(nodeFor(field));
    }

    void recordAllocation(ProgramInfoNode cls) {
      currentNode.connectTo(nodeFor(cls));
      allocated.add(cls);
    }

    bool readRef() {
      final ref = next();
      if (ref is int) {
        final entity = getEntityAt(ref);
        if (entity.type == NodeType.classNode) {
          recordAllocation(entity);
        } else if (entity.type == NodeType.functionNode) {
          recordStaticCall(entity);
        } else if (entity.type == NodeType.other) {
          recordFieldRef(entity);
        }
      } else if (ref == 'S') {
        final String selector = strings[next()];
        recordDynamicCall(selector);
      } else if (ref == 'T') {
        recordInterfaceCall(next());
      } else if (ref == 'C' || ref == 'E') {
        pos--;
        return false;
      } else {
        throw FormatException('unexpected ref: ${ref}');
      }
      return true;
    }

    void readRefs() {
      while (readRef()) {}
    }

    void readEvents() {
      while (true) {
        final op = next();
        switch (op) {
          case 'E': // End.
            return;
          case 'R': // Roots.
            currentNode = nodeFor(program.root);
            readRefs();
            break;
          case 'C': // Function compilation.
            currentNode = nodeFor(getEntityAt(next()));
            readRefs();
            break;
          default:
            throw FormatException('Unknown event: ${op} at ${pos - 1}');
        }
      }
    }

    readEvents();

    // Finally connect nodes representing dynamic and dispatch table calls
    // to their potential targets.
    for (var cls in allocated) {
      for (var fun in cls.children.values.where(dynamicFunctions.contains)) {
        final funNode = nodeFor(fun);

        callNodesBySelector[selectorIdMap[fun]]?.connectTo(funNode);

        final name = fun.name;
        callNodesBySelector[name]?.connectTo(funNode);

        const dynPrefix = 'dyn:';
        const getterPrefix = 'get:';
        const extractorPrefix = '[tear-off-extractor] ';

        if (!name.startsWith(dynPrefix)) {
          // Normal methods can be hit by dyn: selectors if the class
          // does not contain a dedicated dyn: forwarder for this name.
          if (!cls.children.containsKey('$dynPrefix$name')) {
            callNodesBySelector['$dynPrefix$name']?.connectTo(funNode);
          }

          if (name.startsWith(getterPrefix)) {
            // Handle potential calls through getters: getter get:foo can be
            // hit by dyn:foo and foo selectors.
            final targetName = name.substring(getterPrefix.length);
            callNodesBySelector[targetName]?.connectTo(funNode);
            callNodesBySelector['$dynPrefix$targetName']?.connectTo(funNode);
          } else if (name.startsWith(extractorPrefix)) {
            // Handle method tear-off: [tear-off-extractor] get:foo is hit
            // by get:foo.
            callNodesBySelector[name.substring(extractorPrefix.length)]
                ?.connectTo(funNode);
          }
        }
      }
    }

    return CallGraph._(program, nodes, nodeByEntityId);
  }

  /// Return [ProgramInfoNode] representing the entity with the given [id].
  ProgramInfoNode getEntityAt(int id) {
    if (entityById.length <= id) {
      entityById.length = id * 2;
    }

    // Entity records have fixed size which allows us to perform random access.
    const elementsPerEntity = 4;
    return entityById[id] ??= readEntityAt(id * elementsPerEntity);
  }

  /// Read the entity at the given [index] in [entities].
  ProgramInfoNode readEntityAt(int index) {
    final type = entities[index];
    switch (type) {
      case 'C': // Class: 'C', <library-uri-idx>, <name-idx>, 0
        final libraryUri = strings[entities[index + 1]];
        final className = strings[entities[index + 2]];

        return program.makeNode(
            name: className,
            parent: getLibraryNode(libraryUri),
            type: NodeType.classNode);

      case 'S':
      case 'F': // Function: 'F'|'S', <class-idx>, <name-idx>, <selector-id>
        final classNode = getEntityAt(entities[index + 1]);
        final functionName = strings[entities[index + 2]];
        final int selectorId = entities[index + 3];

        final path = Name(functionName).rawComponents;
        if (path.last == 'FfiTrampoline') {
          path[path.length - 1] = '${path.last}@$index';
        }
        var node = program.makeNode(
            name: path.first, parent: classNode, type: NodeType.functionNode);
        for (var name in path.skip(1)) {
          node = program.makeNode(
              name: name, parent: node, type: NodeType.functionNode);
        }
        if (selectorId >= 0) {
          selectorIdMap[node] = selectorId;
        }
        if (type == 'F') {
          dynamicFunctions.add(node);
        }
        return node;

      case 'V': // Field: 'V', <class-idx>, <name-idx>, 0
        final classNode = getEntityAt(entities[index + 1]);
        final fieldName = strings[entities[index + 2]];

        return program.makeNode(
            name: fieldName, parent: classNode, type: NodeType.other);

      default:
        throw FormatException('unrecognized entity type ${type}');
    }
  }

  ProgramInfoNode getLibraryNode(String libraryUri) {
    final package = packageOf(libraryUri);
    var node = program.root;
    if (package != libraryUri) {
      node = program.makeNode(
          name: package, parent: node, type: NodeType.packageNode);
    }
    return program.makeNode(
        name: libraryUri, parent: node, type: NodeType.libraryNode);
  }
}

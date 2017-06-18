package vshaxe.dependencyExplorer;

import haxe.io.Path;
import sys.FileSystem;
import Vscode.*;
import vscode.*;
import js.Promise;
import vshaxe.dependencyExplorer.DependencyResolver;
import vshaxe.dependencyExplorer.HxmlParser;
using Lambda;
using vshaxe.helper.ArrayHelper;

class DependencyExplorer {
    var context:ExtensionContext;
    var configuration:Array<String>;
    var relevantHxmls:Array<String> = [];
    var dependencyNodes:Array<Node> = [];
    var dependencies:DependencyList;
    var refreshNeeded:Bool = true;
    var haxePath:String;

    var _onDidChangeTreeData = new EventEmitter<Node>();

    public var onDidChangeTreeData:Event<Node>;

    public function new(context:ExtensionContext, configuration:Array<String>) {
        this.context = context;
        this.configuration = configuration;

        onDidChangeTreeData = _onDidChangeTreeData.event;
        window.registerTreeDataProvider("haxeDependencies", this);
        commands.registerCommand("haxeDependencies.selectNode", selectNode);
        commands.registerCommand("haxeDependencies.collapseAll", collapseAll);

        var hxmlFileWatcher = workspace.createFileSystemWatcher("**/*.hxml");
        context.subscriptions.push(hxmlFileWatcher.onDidCreate(onDidChangeHxml));
        context.subscriptions.push(hxmlFileWatcher.onDidChange(onDidChangeHxml));
        context.subscriptions.push(hxmlFileWatcher.onDidDelete(onDidChangeHxml));
        context.subscriptions.push(hxmlFileWatcher);

        context.subscriptions.push(workspace.onDidChangeConfiguration(onDidChangeConfiguration));
        haxePath = getHaxePath();
    }

    function onDidChangeHxml(uri:Uri) {
        for (hxml in relevantHxmls) {
            if (Path.normalize(uri.fsPath) == Path.normalize(hxml)) {
                refresh();
            }
        }
    }

    function onDidChangeConfiguration(_) {
        if (haxePath != getHaxePath()) {
            haxePath = getHaxePath();
            refresh();
            dependencies = null; // this is a bit hacky..
        }
    }

    function getHaxePath() {
        var haxePath = workspace.getConfiguration("haxe").get("displayServer").haxePath;
        return if (haxePath == null) "haxe" else haxePath;
    }

    function refreshDependencies():Array<Node> {
        var newDependencies = HxmlParser.extractDependencies(configuration, workspace.rootPath);
        relevantHxmls = newDependencies.hxmls;

        // avoid FS access / creating processes unless there were _actually_ changes
        if (dependencies != null && dependencies.libs.equals(newDependencies.libs) && dependencies.classPaths.equals(newDependencies.classPaths)) {
            return dependencyNodes;
        }
        dependencies = newDependencies;

        return updateNodes(DependencyResolver.resolveDependencies(newDependencies, haxePath));
    }

    function updateNodes(dependencyInfos:Array<DependencyInfo>):Array<Node> {
        var newNodes:Array<Node> = [];

        for (info in dependencyInfos) {
            // don't add duplicates
            if (newNodes.find(d -> d.path == info.path) != null) {
                continue;
            }

            // reuse existing nodes if possible to preserve their collapsibleState
            if (dependencies != null) {
                var oldNode = dependencyNodes.find(d -> d.path == info.path);
                if (oldNode != null) {
                    newNodes.push(oldNode);
                    continue;
                }
            }

            var node = createNode(info);
            if (node != null) {
                newNodes.push(node);
            }
        }

        return newNodes;
    }

    function createNode(info):Node {
        if (info == null) {
            return null;
        }
        var label = info.name;
        if (info.version != null) {
            label += ' (${info.version})';
        }
        return new Node(label, info.path);
    }

    public function onDidChangeDisplayConfiguration(configuration:Array<String>) {
        this.configuration = configuration;
        refresh();
    }

    function refresh() {
        refreshNeeded = true;
        _onDidChangeTreeData.fire();
    }

    public function getTreeItem(element:Node):TreeItem {
        return element;
    }

    public function getChildren(?node:Node):Thenable<Array<Node>> {
        return new Promise(function(resolve, _) {
            if (refreshNeeded) {
                dependencyNodes = refreshDependencies();
                refreshNeeded = false;
            }

            if (node == null) {
                resolve(dependencyNodes);
            } else {
                resolve(getNodeChildren(node));
            }
        });
    }

    function getNodeChildren(node:Node):Array<Node> {
        if (!node.isDirectory) {
            return [];
        }

        var children = [];
        for (file in FileSystem.readDirectory(node.path)) {
            if (!isExcluded(file)) {
                children.push(new Node(file, '${node.path}/$file'));
            }
        };
        return children;
    }

    function isExcluded(file:String):Bool {
        // the proper way of doing this would be to check against the patterns in "files.exclude",
        // but then we'd need to include a lib for glob patterns...
        return file == ".git" || file == ".svn" || file == ".hg" || file == "CVS" || file == ".DS_Store";
    }

    function selectNode(node:Node) {
        if (node.isDirectory) {
            node.collapsibleState = if (node.collapsibleState == Collapsed) Expanded else Collapsed;
        } else {
            workspace.openTextDocument(node.path).then(document -> window.showTextDocument(document, {preview: true}));
        }
    }

    function collapseAll(node:Node) {
        for (node in dependencyNodes) {
            if (node.collapsibleState != None) {
                node.collapsibleState = Collapsed;
            }
        }
        _onDidChangeTreeData.fire();
    }
}

private class Node extends TreeItem {
    public var path(default,null):String;
    public var isDirectory(default,null):Bool;

    public function new(label:String, path:String) {
        super(label);
        this.path = path;
        isDirectory = FileSystem.isDirectory(path);
        if (isDirectory) {
            collapsibleState = Collapsed;
        }

        command = {
            command: "haxeDependencies.selectNode",
            arguments: [this],
            title: "Open File"
        };
    }
}
import 'package:angular/src/core/linker/view_type.dart' show ViewType;
import 'package:angular_compiler/angular_compiler.dart';
import 'package:angular/src/facade/exceptions.dart' show BaseException;
import 'package:angular/src/transform/common/names.dart'
    show toTemplateExtension;

import '../compile_metadata.dart'
    show
        CompileDirectiveMetadata,
        CompileIdentifierMetadata,
        CompilePipeMetadata,
        CompileProviderMetadata,
        CompileQueryMetadata,
        CompileTokenMap;
import '../identifiers.dart';
import '../output/output_ast.dart' as o;
import '../template_ast.dart'
    show TemplateAst, ElementAst, VariableAst, ProviderAst, ProviderAstType;
import 'compile_binding.dart' show CompileBinding;
import 'compile_element.dart' show CompileElement, CompileNode;
import 'compile_method.dart' show CompileMethod;
import 'compile_pipe.dart' show CompilePipe;
import 'compile_query.dart' show CompileQuery, addQueryToTokenMap;
import 'constants.dart' show appViewRootElementName;
import 'view_compiler_utils.dart'
    show
        createDbgElementCall,
        cachedParentIndexVarName,
        getViewFactoryName,
        injectFromViewParentInjector,
        getParentRenderNode,
        identifierFromTagName,
        ViewCompileDependency;
import 'view_name_resolver.dart';

/// Visibility of NodeReference within AppView implementation.
enum NodeReferenceVisibility {
  classPublic, // Visible across build and change detectors or other closures.
  build, // Only visible inside DOM build process.
}

/// Reference to html node created during AppView build.
class NodeReference {
  final CompileElement parent;
  final int nodeIndex;
  final String _name;
  final TemplateAst _ast;

  NodeReferenceVisibility _visibility = NodeReferenceVisibility.classPublic;

  NodeReference(this.parent, this.nodeIndex, this._ast)
      : _name = '_el_$nodeIndex';
  NodeReference.textNode(this.parent, this.nodeIndex, this._ast)
      : _name = '_text_$nodeIndex';
  NodeReference.anchor(this.parent, this.nodeIndex, this._ast)
      : _name = '_anchor_$nodeIndex',
        _visibility = NodeReferenceVisibility.build;
  NodeReference.appViewRoot()
      : parent = null,
        nodeIndex = -1,
        _ast = null,
        _name = appViewRootElementName;

  void lockVisibility(NodeReferenceVisibility visibility) {
    if (_visibility != NodeReferenceVisibility.classPublic &&
        _visibility != visibility) {
      throw new ArgumentError('The reference was already restricted. '
          'Can\'t change access to reference.');
    }
    _visibility = visibility;
  }

  o.Expression toReadExpr() {
    assert(_ast != null);
    return _visibility == NodeReferenceVisibility.classPublic
        ? new o.ReadClassMemberExpr(_name)
        : o.variable(_name);
  }

  o.Expression toWriteExpr(o.Expression value) {
    return _visibility == NodeReferenceVisibility.classPublic
        ? new o.WriteClassMemberExpr(_name, value)
        : o.variable(_name).set(value);
  }
}

/// Reference to html node created during AppView build.
class AppViewReference {
  final CompileElement parent;
  final int nodeIndex;
  final String _name;

  AppViewReference(this.parent, this.nodeIndex)
      : _name = '_compView_$nodeIndex';

  o.Expression toReadExpr() {
    return new o.ReadClassMemberExpr(_name);
  }

  o.Expression toWriteExpr(o.Expression value) {
    return new o.WriteClassMemberExpr(_name, value);
  }
}

/// Interface to generate a build function for an AppView.
abstract class AppViewBuilder {
  /// Creates an unbound literal text node.
  NodeReference createTextNode(
      CompileElement parent, int nodeIndex, String text, TemplateAst ast);

  NodeReference createBoundTextNode(
      CompileElement parent, int nodeIndex, TemplateAst ast);

  /// Adds a field member that holds the reference to a child app view for
  /// a hosted component.
  AppViewReference createAppView(
      CompileElement parent,
      CompileDirectiveMetadata childComponent,
      NodeReference elementRef,
      int nodeIndex,
      bool isDeferred,
      ElementAst ast,
      List<ViewCompileDependency> targetDeps);

  /// Create a view container for a given node reference and index.
  ///
  /// isPrivate indicates that the view container is only used for an embedded
  /// view and is not publicly shared through injection or view query.
  o.Expression createViewContainer(
      NodeReference nodeReference, int nodeIndex, bool isPrivate,
      [int parentNodeIndex]);

  /// Creates a field to store a stream subscription to be destroyed.
  void createSubscription(o.Expression streamReference, o.Expression handler,
      {bool isMockLike: false});

  /// Add DOM event listener.
  void addDomEventListener(
      NodeReference node, String eventName, o.Expression handler);

  /// Adds event listener that is routed through EventManager for custom
  /// events.
  void addCustomEventListener(
      NodeReference node, String eventName, o.Expression handler);

  /// Create a QueryList instance to update matches.
  o.Expression createQueryListField(
      CompileQueryMetadata query, String propertyName);

  /// Initializes query target on component at startup/build time.
  void updateQueryAtStartup(CompileQuery query);

  /// Creates a provider as a field or local expression.
  o.Expression createProvider(
      String propName,
      CompileDirectiveMetadata directiveMetadata,
      ProviderAst provider,
      List<o.Expression> providerValueExpressions,
      bool isMulti,
      bool isEager,
      CompileElement compileElement,
      {bool forceDynamic: false});

  /// Calls function directive on view startup.
  void callFunctionalDirective(
      CompileProviderMetadata provider, List<o.Expression> parameters);

  /// Creates a pipe and stores reference expression in fieldName.
  void createPipeInstance(String pipeFieldName, CompilePipeMetadata pipeMeta);

  /// Constructs a pure proxy and stores instance in class member.
  void createPureProxy(
      o.Expression fn, num argCount, o.ReadClassMemberExpr pureProxyProp);

  /// Finally writes build statements into target.
  void writeBuildStatements(List<o.Statement> targetStatements);
}

/// Represents data to generate a host, component or embedded AppView.
///
/// Members and method builders are populated by ViewBuilder.
class CompileView implements AppViewBuilder {
  final CompileDirectiveMetadata component;
  final CompilerFlags genConfig;
  final List<CompilePipeMetadata> pipeMetas;
  final o.Expression styles;
  final Map<String, String> deferredModules;
  final _cloneAnchorNodeExpr = o
      .importExpr(Identifiers.ngAnchor)
      .callMethod('clone', [o.literal(false)]);

  int viewIndex;
  CompileElement declarationElement;
  List<VariableAst> templateVariables;
  ViewType viewType;
  CompileTokenMap<List<CompileQuery>> viewQueries;

  /// Contains references to view children so we can generate code for
  /// change detection and destroy.
  final List<o.Expression> _viewChildren = [];

  /// Flat list of all nodes inside the template including text nodes.
  List<CompileNode> nodes = [];

  /// List of references to top level nodes in view.
  List<o.Expression> rootNodesOrViewContainers = [];

  /// List of references to view containers used by embedded templates
  /// and child components.
  List<o.Expression> viewContainers = [];
  final _bindings = <CompileBinding>[];
  List<o.Statement> classStatements = [];
  CompileMethod createMethod;
  CompileMethod injectorGetMethod;
  CompileMethod updateContentQueriesMethod;
  CompileMethod dirtyParentQueriesMethod;
  CompileMethod updateViewQueriesMethod;
  CompileMethod detectChangesInInputsMethod;
  CompileMethod detectChangesRenderPropertiesMethod;
  CompileMethod detectHostChangesMethod;
  CompileMethod afterContentLifecycleCallbacksMethod;
  CompileMethod afterViewLifecycleCallbacksMethod;
  CompileMethod destroyMethod;

  /// List of methods used to handle events with non standard parameters in
  /// handlers or events with multiple actions.
  List<o.ClassMethod> eventHandlerMethods = [];
  List<o.ClassGetter> getters = [];
  List<o.Expression> subscriptions = [];
  bool subscribesToMockLike = false;
  CompileView componentView;
  var purePipes = new Map<String, CompilePipe>();
  List<CompilePipe> pipes = [];
  String className;
  o.OutputType classType;
  o.ReadVarExpr viewFactory;
  bool requiresOnChangesCall = false;
  var pipeCount = 0;
  ViewNameResolver nameResolver;

  CompileView(
      this.component,
      this.genConfig,
      this.pipeMetas,
      this.styles,
      this.viewIndex,
      this.declarationElement,
      this.templateVariables,
      this.deferredModules) {
    createMethod = new CompileMethod(genDebugInfo);
    injectorGetMethod = new CompileMethod(genDebugInfo);
    updateContentQueriesMethod = new CompileMethod(genDebugInfo);
    dirtyParentQueriesMethod = new CompileMethod(genDebugInfo);
    updateViewQueriesMethod = new CompileMethod(genDebugInfo);
    detectChangesInInputsMethod = new CompileMethod(genDebugInfo);
    detectChangesRenderPropertiesMethod = new CompileMethod(genDebugInfo);
    afterContentLifecycleCallbacksMethod = new CompileMethod(genDebugInfo);
    afterViewLifecycleCallbacksMethod = new CompileMethod(genDebugInfo);
    destroyMethod = new CompileMethod(genDebugInfo);
    nameResolver = new ViewNameResolver(this);
    viewType = getViewType(component, viewIndex);
    className = '${viewIndex == 0 && viewType != ViewType.HOST ? '' : '_'}'
        'View${component.type.name}$viewIndex';
    classType = o.importType(new CompileIdentifierMetadata(name: className));
    viewFactory = o.variable(getViewFactoryName(component, viewIndex));
    switch (viewType) {
      case ViewType.HOST:
      case ViewType.COMPONENT:
        componentView = this;
        break;
      default:
        // An embedded template uses it's declaration element's componentView.
        componentView = declarationElement.view.componentView;
        break;
    }
    viewQueries = new CompileTokenMap<List<CompileQuery>>();
    if (viewType == ViewType.COMPONENT) {
      var directiveInstance = new o.ReadClassMemberExpr('ctx');
      var queryIndex = -1;
      for (CompileQueryMetadata queryMeta in component.viewQueries) {
        queryIndex++;
        var propName = '_viewQuery_${queryMeta.selectors[0].name}_$queryIndex';
        var queryList = createQueryListField(queryMeta, propName);
        var query =
            new CompileQuery(queryMeta, queryList, directiveInstance, this);
        addQueryToTokenMap(viewQueries, query);
      }
    }

    for (var variable in templateVariables) {
      nameResolver.addLocal(
        variable.name,
        new o.ReadClassMemberExpr('locals').key(o.literal(variable.value)),
        variable.type, // NgFor locals are augmented with type information.
      );
    }
    if (declarationElement.parent != null) {
      declarationElement.setEmbeddedView(this);
    }
    if (deferredModules == null) {
      throw new ArgumentError();
    }
  }

  bool get genDebugInfo => genConfig.genDebugInfo;

  // Adds reference to a child view.
  void addViewChild(o.Expression componentViewExpr) {
    _viewChildren.add(componentViewExpr);
  }

  // Returns list of references to view children.
  List<o.Expression> get viewChildren => _viewChildren;

  // Adds a binding to the view and returns binding index.
  int addBinding(CompileNode node, TemplateAst sourceAst) {
    _bindings.add(new CompileBinding(node, sourceAst));
    return _bindings.length - 1;
  }

  void afterNodes() {
    for (var pipe in pipes) {
      pipe.create();
    }
    for (var queries in viewQueries.values) {
      for (var query in queries) {
        query.generateImmediateUpdate(createMethod);
        query.generateDynamicUpdate(updateContentQueriesMethod);
      }
    }
  }

  @override
  NodeReference createTextNode(
      CompileElement parent, int nodeIndex, String text, TemplateAst ast) {
    var renderNode = new NodeReference.textNode(parent, nodeIndex, ast);
    renderNode.lockVisibility(NodeReferenceVisibility.build);
    createMethod.addStmt(new o.DeclareVarStmt(
        renderNode._name,
        o.importExpr(Identifiers.HTML_TEXT_NODE).instantiate([o.literal(text)]),
        o.importType(Identifiers.HTML_TEXT_NODE)));
    var parentRenderNodeExpr = getParentRenderNode(this, parent);
    if (parentRenderNodeExpr != null && parentRenderNodeExpr != o.NULL_EXPR) {
      // Write append code.
      createMethod.addStmt(parentRenderNodeExpr
          .callMethod('append', [renderNode.toReadExpr()]).toStmt());
    }
    if (genConfig.genDebugInfo) {
      createMethod.addStmt(
          createDbgElementCall(renderNode.toReadExpr(), nodeIndex, ast));
    }
    return renderNode;
  }

  @override
  NodeReference createBoundTextNode(
      CompileElement parent, int nodeIndex, TemplateAst ast) {
    // If Text field is bound, we need access to the renderNode beyond
    // build method and write reference to class member.
    NodeReference renderNode =
        new NodeReference.textNode(parent, nodeIndex, ast);
    nameResolver.addField(new o.ClassField(renderNode._name,
        outputType: o.importType(Identifiers.HTML_TEXT_NODE),
        modifiers: const [o.StmtModifier.Private]));

    var parentRenderNodeExpr = getParentRenderNode(this, parent);
    var createRenderNodeExpr = renderNode.toWriteExpr(
        o.importExpr(Identifiers.HTML_TEXT_NODE).instantiate([o.literal('')]));
    createMethod.addStmt(createRenderNodeExpr.toStmt());

    if (parentRenderNodeExpr != null && parentRenderNodeExpr != o.NULL_EXPR) {
      // Write append code.
      createMethod.addStmt(parentRenderNodeExpr
          .callMethod('append', [renderNode.toReadExpr()]).toStmt());
    }
    if (genConfig.genDebugInfo) {
      createMethod.addStmt(
          createDbgElementCall(renderNode.toReadExpr(), nodeIndex, ast));
    }
    return renderNode;
  }

  NodeReference createViewContainerAnchor(
      CompileElement parent, int nodeIndex, TemplateAst ast) {
    NodeReference renderNode = new NodeReference.anchor(parent, nodeIndex, ast);
    var assignCloneAnchorNodeExpr =
        (renderNode.toReadExpr() as o.ReadVarExpr).set(_cloneAnchorNodeExpr);
    createMethod.addStmt(assignCloneAnchorNodeExpr.toDeclStmt());
    var parentNode = getParentRenderNode(this, parent);
    if (parentNode != o.NULL_EXPR) {
      var addCommentStmt =
          parentNode.callMethod('append', [renderNode.toReadExpr()]).toStmt();
      createMethod.addStmt(addCommentStmt);
    }

    if (genConfig.genDebugInfo) {
      createMethod.addStmt(
          createDbgElementCall(renderNode.toReadExpr(), nodeIndex, ast));
    }
    return renderNode;
  }

  @override
  AppViewReference createAppView(
      CompileElement parent,
      CompileDirectiveMetadata childComponent,
      NodeReference elementRef,
      int nodeIndex,
      bool isDeferred,
      ElementAst ast,
      List<ViewCompileDependency> targetDeps) {
    CompileIdentifierMetadata componentViewIdentifier =
        new CompileIdentifierMetadata(name: 'View${childComponent.type.name}0');
    targetDeps.add(
        new ViewCompileDependency(childComponent, componentViewIdentifier));

    bool isHostRootView = nodeIndex == 0 && viewType == ViewType.HOST;
    var elementType = isHostRootView
        ? Identifiers.HTML_HTML_ELEMENT
        : identifierFromTagName(ast.name);

    if (!isHostRootView) {
      nameResolver.addField(new o.ClassField(elementRef._name,
          outputType: o.importType(elementType),
          modifiers: const [o.StmtModifier.Private]));
    }

    AppViewReference appViewRef = new AppViewReference(parent, nodeIndex);

    var appViewType = isDeferred
        ? o.importType(Identifiers.AppView, null)
        : o.importType(componentViewIdentifier);

    nameResolver
        .addField(new o.ClassField(appViewRef._name, outputType: appViewType));

    if (isDeferred) {
      // When deferred, we use AppView<dynamic> as type to store instance
      // of component and create the instance using:
      // deferredLibName.viewFactory_SomeComponent(...)
      CompileIdentifierMetadata nestedComponentIdentifier =
          new CompileIdentifierMetadata(
              name: getViewFactoryName(childComponent, 0));
      targetDeps.add(
          new ViewCompileDependency(childComponent, nestedComponentIdentifier));

      var importExpr = o.importExpr(nestedComponentIdentifier);
      createMethod.addStmt(new o.WriteClassMemberExpr(appViewRef._name,
          importExpr.callFn([o.THIS_EXPR, o.literal(nodeIndex)])).toStmt());
    } else {
      // Create instance of component using ViewSomeComponent0 AppView.
      var createComponentInstanceExpr = o
          .importExpr(componentViewIdentifier)
          .instantiate([o.THIS_EXPR, o.literal(nodeIndex)]);
      createMethod.addStmt(new o.WriteClassMemberExpr(
              appViewRef._name, createComponentInstanceExpr)
          .toStmt());
    }
    return appViewRef;
  }

  @override
  o.Expression createViewContainer(
      NodeReference nodeReference, int nodeIndex, bool isPrivate,
      [int parentNodeIndex]) {
    o.Expression renderNode = nodeReference.toReadExpr();
    var fieldName = '_appEl_$nodeIndex';
    // Create instance field for app element.
    nameResolver.addField(new o.ClassField(fieldName,
        outputType: o.importType(Identifiers.ViewContainer),
        modifiers: [o.StmtModifier.Private]));

    // Write code to create an instance of ViewContainer.
    // Example:
    //     this._appEl_2 = new import7.ViewContainer(2,0,this,this._anchor_2);
    var statement = new o.WriteClassMemberExpr(
        fieldName,
        o.importExpr(Identifiers.ViewContainer).instantiate([
          o.literal(nodeIndex),
          o.literal(parentNodeIndex),
          o.THIS_EXPR,
          renderNode
        ])).toStmt();
    createMethod.addStmt(statement);
    var appViewContainer = new o.ReadClassMemberExpr(fieldName);
    if (!isPrivate) {
      viewContainers.add(appViewContainer);
    }
    return appViewContainer;
  }

  @override
  void createSubscription(o.Expression streamReference, o.Expression handler,
      {bool isMockLike: false}) {
    final subscription = o.variable('subscription_${subscriptions.length}');
    subscriptions.add(subscription);
    createMethod.addStmt(subscription
        .set(streamReference.callMethod(
            o.BuiltinMethod.SubscribeObservable, [handler],
            checked: isMockLike))
        .toDeclStmt(null, [o.StmtModifier.Final]));
    if (isMockLike) {
      subscribesToMockLike = true;
    }
  }

  @override
  void addDomEventListener(
      NodeReference node, String eventName, o.Expression handler) {
    var listenExpr = node
        .toReadExpr()
        .callMethod('addEventListener', [o.literal(eventName), handler]);
    createMethod.addStmt(listenExpr.toStmt());
  }

  @override
  void addCustomEventListener(
      NodeReference node, String eventName, o.Expression handler) {
    final appViewUtilsExpr = o.importExpr(Identifiers.appViewUtils);
    final eventManagerExpr = appViewUtilsExpr.prop('eventManager');
    var listenExpr = eventManagerExpr.callMethod(
        'addEventListener', [node.toReadExpr(), o.literal(eventName), handler]);
    createMethod.addStmt(listenExpr.toStmt());
  }

  @override
  o.Expression createQueryListField(
      CompileQueryMetadata query, String propertyName) {
    nameResolver.addField(new o.ClassField(propertyName,
        outputType: o.importType(Identifiers.QueryList),
        modifiers: [o.StmtModifier.Private]));
    createMethod.addStmt(new o.WriteClassMemberExpr(
            propertyName, o.importExpr(Identifiers.QueryList).instantiate([]))
        .toStmt());
    return new o.ReadClassMemberExpr(propertyName);
  }

  @override
  void updateQueryAtStartup(CompileQuery query) {
    query.generateImmediateUpdate(createMethod);
  }

  /// Creates a class field and assigns the resolvedProviderValueExpr.
  ///
  /// Eager Example:
  ///   _TemplateRef_9_4 =
  ///       new TemplateRef(_appEl_9,viewFactory_SampleComponent7);
  ///
  /// Lazy:
  ///
  /// TemplateRef _TemplateRef_9_4;
  ///
  @override
  o.Expression createProvider(
      String propName,
      CompileDirectiveMetadata directiveMetadata,
      ProviderAst provider,
      List<o.Expression> providerValueExpressions,
      bool isMulti,
      bool isEager,
      CompileElement compileElement,
      {bool forceDynamic: false}) {
    var resolvedProviderValueExpr;
    var type;
    if (isMulti) {
      resolvedProviderValueExpr = o.literalArr(providerValueExpressions);
      type = new o.ArrayType(provider.multiProviderType != null
          ? o.importType(provider.multiProviderType)
          : o.DYNAMIC_TYPE);
    } else {
      resolvedProviderValueExpr = providerValueExpressions[0];
      type = providerValueExpressions[0].type;
    }

    type ??= o.DYNAMIC_TYPE;

    bool providerHasChangeDetector =
        provider.providerType == ProviderAstType.Directive &&
            directiveMetadata != null &&
            directiveMetadata.requiresDirectiveChangeDetector;

    CompileIdentifierMetadata changeDetectorType;
    if (providerHasChangeDetector) {
      changeDetectorType = new CompileIdentifierMetadata(
          name: directiveMetadata.identifier.name + 'NgCd',
          moduleUrl:
              toTemplateExtension(directiveMetadata.identifier.moduleUrl));
    }

    if (isEager) {
      // Check if we need to reach this directive or component beyond the
      // contents of the build() function. Otherwise allocate locally.
      if (compileElement.publishesTemplateRef ||
          compileElement.hasTemplateRefQuery ||
          provider.dynamicallyReachable) {
        if (providerHasChangeDetector) {
          nameResolver.addField(new o.ClassField(propName,
              outputType: o.importType(changeDetectorType),
              modifiers: const [o.StmtModifier.Private]));
          createMethod.addStmt(new o.WriteClassMemberExpr(
              propName,
              o
                  .importExpr(changeDetectorType)
                  .instantiate([resolvedProviderValueExpr])).toStmt());
          return new o.ReadPropExpr(
              new o.ReadClassMemberExpr(
                  propName, o.importType(changeDetectorType)),
              'instance',
              outputType: forceDynamic ? o.DYNAMIC_TYPE : type);
        } else {
          nameResolver.addField(new o.ClassField(propName,
              outputType: forceDynamic ? o.DYNAMIC_TYPE : type,
              modifiers: const [o.StmtModifier.Private]));
          createMethod.addStmt(
              new o.WriteClassMemberExpr(propName, resolvedProviderValueExpr)
                  .toStmt());
        }
      } else {
        // Since provider is not dynamically reachable and we only need
        // the provider locally in build, create a local var.
        var localVar =
            o.variable(propName, forceDynamic ? o.DYNAMIC_TYPE : type);
        createMethod
            .addStmt(localVar.set(resolvedProviderValueExpr).toDeclStmt());
        return localVar;
      }
    } else {
      // We don't have to eagerly initialize this object. Add an uninitialized
      // class field and provide a getter to construct the provider on demand.
      var internalField = '_$propName';
      nameResolver.addField(new o.ClassField(internalField,
          outputType: forceDynamic
              ? o.DYNAMIC_TYPE
              : (providerHasChangeDetector
                  ? o.importType(changeDetectorType)
                  : type),
          modifiers: const [o.StmtModifier.Private]));
      var getter = new CompileMethod(genDebugInfo);
      getter.resetDebugInfo(compileElement.nodeIndex, compileElement.sourceAst);

      if (providerHasChangeDetector) {
        resolvedProviderValueExpr = o
            .importExpr(changeDetectorType)
            .instantiate([resolvedProviderValueExpr]);
      }
      // Note: Equals is important for JS so that it also checks the undefined case!
      var statements = <o.Statement>[
        new o.WriteClassMemberExpr(internalField, resolvedProviderValueExpr)
            .toStmt()
      ];
      var readVars = o.findReadVarNames(statements);
      if (readVars.contains(cachedParentIndexVarName)) {
        statements.insert(
            0,
            new o.DeclareVarStmt(cachedParentIndexVarName,
                new o.ReadClassMemberExpr('viewData').prop('parentIndex')));
      }
      getter.addStmt(new o.IfStmt(
          new o.ReadClassMemberExpr(internalField).isBlank(), statements));
      getter.addStmt(
          new o.ReturnStatement(new o.ReadClassMemberExpr(internalField)));
      getters.add(new o.ClassGetter(
          propName,
          getter.finish(),
          forceDynamic
              ? o.DYNAMIC_TYPE
              : (providerHasChangeDetector ? changeDetectorType : type)));
    }
    return new o.ReadClassMemberExpr(propName);
  }

  @override
  void callFunctionalDirective(
      CompileProviderMetadata provider, List<o.Expression> parameters) {
    // Add functional directive invocation.
    final invokeExpr = o.importExpr(provider.useClass).callFn(parameters);
    createMethod.addStmt(invokeExpr.toStmt());
  }

  @override
  void createPipeInstance(String name, CompilePipeMetadata pipeMeta) {
    var deps = pipeMeta.type.diDeps.map((diDep) {
      if (diDep.token
          .equalsTo(identifierToken(Identifiers.ChangeDetectorRef))) {
        return new o.ReadClassMemberExpr('ref');
      }
      return injectFromViewParentInjector(this, diDep.token, false);
    }).toList();
    nameResolver.addField(new o.ClassField(name,
        outputType: o.importType(pipeMeta.type),
        modifiers: [o.StmtModifier.Private]));
    createMethod.resetDebugInfo(null, null);
    createMethod.addStmt(new o.WriteClassMemberExpr(
            name, o.importExpr(pipeMeta.type).instantiate(deps))
        .toStmt());
  }

  @override
  void createPureProxy(
    o.Expression fn,
    num argCount,
    o.ReadClassMemberExpr pureProxyProp, {
    o.OutputType pureProxyType,
  }) {
    nameResolver.addField(
      new o.ClassField(
        pureProxyProp.name,
        outputType: pureProxyType,
        modifiers: const [o.StmtModifier.Private],
      ),
    );
    var pureProxyId = argCount < Identifiers.pureProxies.length
        ? Identifiers.pureProxies[argCount]
        : null;
    if (pureProxyId == null) {
      throw new BaseException(
          'Unsupported number of argument for pure functions: $argCount');
    }
    createMethod.addStmt(new o.ReadClassMemberExpr(pureProxyProp.name)
        .set(o.importExpr(pureProxyId).callFn([fn]))
        .toStmt());
  }

  @override
  void writeBuildStatements(List<o.Statement> targetStatements) {
    targetStatements.addAll(createMethod.finish());
  }
}

ViewType getViewType(
    CompileDirectiveMetadata component, int embeddedTemplateIndex) {
  if (embeddedTemplateIndex > 0) {
    return ViewType.EMBEDDED;
  } else if (component.type.isHost) {
    return ViewType.HOST;
  } else {
    return ViewType.COMPONENT;
  }
}

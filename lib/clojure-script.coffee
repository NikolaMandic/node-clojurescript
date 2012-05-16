` // TOP `

clc            = require 'cli-color'
fs             = require 'fs'
Module         = require 'module'
path           = require 'path'
readline       = require 'readline'
restify        = require 'restify'
shell          = require 'shelljs'
util           = require 'util'
uuid           = require 'node-uuid'
vm             = require 'vm'

{EventEmitter} = require 'events'
{inspect}      = require 'util'
{Script}       = vm
{spawn, exec}  = require 'child_process'

ClojureScript = (port) ->
  if port
    ClojureScript.usingPort = parseInt port
  else
    ClojureScript.usingPort = ClojureScript.defaultPort
  ClojureScript.client      = require ( __dirname + '/support/js/detached-jvm-client' )
  ClojureScript.builder     = ClojureScript.remoteBuilder
  ClojureScript

ClojureScript.VERSION = '0.1.4-pre'

ClojureScript.CLJS_VERSION = 'r1211++'

ClojureScript.Tempdir  = require 'temporary/lib/dir'
ClojureScript.Tempfile = require 'temporary/lib/file'
ClojureScript.tmp = new ClojureScript.Tempdir

ClojureScript.defaultJavaOptions = ''
ClojureScript.javaOptions = ClojureScript.defaultJavaOptions

ClojureScript.defaultCljscOptions = '{:optimizations :simple :target :nodejs :pretty-print false}'
ClojureScript.cljscOptions = ClojureScript.defaultCljscOptions


ClojureScript.initJava = (options) ->
  @java = java = require 'java'
  if options then java.options.push ( '-' + jo ) for jo in ( options.split ' ' )
  java.classpath.push ( __dirname + '/support/clojure-clojurescript/lib/clojure.jar' )
  java.classpath.push ( __dirname + '/support/clojure-clojurescript/lib/compiler.jar' )
  java.classpath.push ( __dirname + '/support/clojure-clojurescript/lib/goog.jar' )
  java.classpath.push ( __dirname + '/support/clojure-clojurescript/lib/js.jar' )
  java.classpath.push ( __dirname + '/support/clojure-clojurescript/src/clj' )
  java.classpath.push ( __dirname + '/support/clojure-clojurescript/src/cljs' )
  java.classpath.push ( __dirname + '/support/clj' )


ClojureScript.initClojureCompiler = (javaOptions = ClojureScript.javaOptions) ->
  if ( not @java ) then @initJava javaOptions
  @StringReader = StringReader = @java.import 'java.io.StringReader'
  @ClojureCompiler = ClojureCompiler = @java.import 'clojure.lang.Compiler'

  closureClj = fs.readFileSync ( __dirname + '/support/clojure-clojurescript/src/clj/cljs/closure.clj' ), 'utf8'
  closureCljSR = new StringReader closureClj
  ClojureCompiler.loadSync closureCljSR

  @clojureBuild = @java.callStaticMethodSync 'clojure.lang.RT', 'var', 'cljs.closure', 'build'

  pomgClj = fs.readFileSync ( __dirname + '/support/clj/pomegranate.clj' ), 'utf8'
  pomgCljSR = new StringReader pomgClj
  ClojureCompiler.loadSync pomgCljSR

  @clojureAddClassPath = @java.callStaticMethodSync 'clojure.lang.RT', 'var', 'pomegranate', 'add-classpath'

  @addClassPath = (cp) ->
    @clojureAddClassPath.invokeSync cp


ClojureScript.addClassPath = (cp) ->
  if ( not @ClojureCompiler ) then @initClojureCompiler()
  @addClassPath cp


pathCompiledCoreJS = __dirname + '/support/out/cljs/core.js'
compiledCoreJS = ''
ClojureScript.compiledCoreJS = -> compiledCoreJS
if ( path.existsSync pathCompiledCoreJS )
  compiledCoreJS = fs.readFileSync pathCompiledCoreJS, 'utf8'
  ClojureScript.compiledCoreJS.exists = true


pathCompiledNodejsJS = __dirname + '/support/out/cljs/nodejs.js'
compiledNodejsJS = ''
ClojureScript.compiledNodejsJS = -> compiledNodejsJS
if ( path.existsSync pathCompiledNodejsJS )
  compiledNodejsJS = fs.readFileSync pathCompiledNodejsJS, 'utf8'
  ClojureScript.compiledNodejsJS.exists = true


ClojureScript.tmpOut = (options) -> options[0...( options.length - 1 )] + " :tmp-out \"#{ @tmp.path }\"}"

ClojureScript.defaultPort = 4242

ClojureScript.localBuilder = (options, cljscOptions, callback, javaOptions = ClojureScript.javaOptions) ->
  if ( not ClojureScript.java ) then ClojureScript.initJava javaOptions
  if ( not ClojureScript.ClojureCompiler ) then ClojureScript.initClojureCompiler()

  if options.classpath
    ClojureScript.addClassPath options.classpath

  header = "Generated by ClojureScript #{ClojureScript.CLJS_VERSION} (ncljsc v#{ClojureScript.VERSION})"

  # presently, attempting asynchronous calls to cljs.closure/build is
  # resulting in exceptions mentioning java.lang.NullPointerException,
  # so for now options.async will never be set to true by parseOptions
  # in command.coffee
  if options.async
    ClojureScript.clojureBuild.invoke options.path, cljscOptions, (err, js) ->
      if err
        return ( callback err, null )

      if not options.bare
        js = ";(function() {\n  #{js}\n}).call(this);\n"
        return ( callback null, js ) unless options.header

        callback null, "// #{header}\n#{js}"

  else
    try
      js = ClojureScript.clojureBuild.invokeSync options.path, cljscOptions
      if not options.bare
        js = ";(function() {\n  #{js}\n}).call(this);\n"
      return ( callback null, js ) unless options.header

    catch err
      callback err, null

    # callback is called synchronously in this case
    callback null, "// #{header}\n#{js}"


ClojureScript.remoteBuilder = (options, cljscOptions, callback) ->
  async = options.async
  delete options.async
  options.cljscOptions = cljscOptions
  options.port = ClojureScript.usingPort

  if async
    buildRequest = (options, callback) ->
      ClojureScript.client.buildRequest options, (err, response) ->
        err = err or response.err
        js  = response.js
        callback err, js

    if ClojureScript.detachedJVMcreds
      creds = ClojureScript.detachedJVMcreds
      options.username = creds.username
      options.password = creds.password
      buildRequest options, callback

    else
      ClojureScript.client.credsRequest options.port, (err, response) ->
        if err then return ( callback err, null )
        fs.readFile response.path, 'utf8', (err, data) ->
          if err then return ( callback err, null )

          try
            ClojureScript.detachedJVMcreds = creds = JSON.parse data
            options.username = creds.username
            options.password = creds.password
            buildRequest options, callback

          catch err
            callback err, null

  else

    buildRequest = (options, callback) ->
      tmpfile = new ClojureScript.Tempfile
      options = JSON.stringify options
      fs.writeFileSync tmpfile.path, options, 'utf8'
      response = shell.exec ( 'node ' + __dirname + \
                              '/support/js/detached-jvm-client.js --request-build ' + tmpfile.path ), { async: false, silent: true }
      if response.code is 0

        try
          response = JSON.parse response.output
          if response.err
            err = new Error response.err
          else
            err = null
          js  = response.js
          callback err, js

        catch err
          callback err, null

      else
        callback ( new Error "http request script exited with code #{response.code}" ), null

    if ClojureScript.detachedJVMcreds
      creds = ClojureScript.detachedJVMcreds
      options.username = creds.username
      options.password = creds.password
      buildRequest options, callback

    else
      response = shell.exec ( 'node ' + __dirname + \
                              '/support/js/detached-jvm-client.js --request-creds ' + options.port ), { async: false, silent: true }
      if response.code is 0

        try
          response = JSON.parse response.output
          if response.err
            err = new Error response.err
            return ( callback err, null )

          try
            data = fs.readFileSync response.path, 'utf8'
            ClojureScript.detachedJVMcreds = creds = JSON.parse data
            options.username = creds.username
            options.password = creds.password
            buildRequest options, callback

          catch err
            callback err, null

        catch err
          callback err, null

      else
        callback ( new Error "http request script exited with code #{response.code}" ), null


# this default may be modified at runtime depending on cli options or
# arguments passed to the required module
ClojureScript.builder = ClojureScript.localBuilder


ClojureScript.build = (options, builder, callback, cljscOptions = ClojureScript.cljscOptions, javaOptions = ClojureScript.javaOptions) ->
  if not options.path then return ( callback ( new Error 'no source path specified' ), null )

  if ( cljscOptions isnt @cljscOptions )
    cljscOptions = cljscOptions.match /^\s*(\{.*\})\s*$/
    if ( not cljscOptions )
      return ( callback ( new Error 'malformed ClojureScript options hash-map' ), null )
    else
      cljscOptions = cljscOptions[1]

    if ( ( cljscOptions.match /\:output-dir\s*\'.*\'/ ) or \
         ( cljscOptions.match /\:output-dir\s*[^\'\"]*(\:|(\}$))/ ) or \
         ( cljscOptions.match /\:output-dir\s*\'[^\']*(\:|(\}$))/ ) or \
         ( cljscOptions.match /\:output-dir\s*\"[^\"]*(\:|(\}$))/ ) or \
         ( cljscOptions.match /\:output-dir\s*[^\']*\'\s*(\:|(\}$))/ ) or \
         ( cljscOptions.match /\:output-dir\s*[^\"]*\"\s*(\:|(\}$))/ ) )
      return ( callback ( new Error 'path specified as :output-dir must be wrapped in double-quotes' ), null )

    outputdir = cljscOptions.match /\:output-dir\s*(\".*\")/
    if outputdir
      outputdir = outputdir[1]
      outputdir = outputdir[1...( outputdir.length - 1 )]
      outputdir = path.resolve ( path.normalize outputdir )
      if ( not path.existsSync outputdir )
        return ( callback ( new Error 'path specified as :output-dir must exist' ), null )
      if ( not ( fs.statSync outputdir ).isDirectory() )
        return ( callback ( new Error 'path specified as :output-dir must be a directory' ), null )
      @['output-dir'] = outputdir

  if ( not outputdir? )
    @['output-dir'] = outputdir = @tmp.path
    cljscOptions = @tmpOut cljscOptions

  outcljs = outputdir + '/cljs'
  if ( not ( path.existsSync outcljs ) )
    fs.mkdirSync outcljs

  if @compiledCoreJS.exists
    outcljscore = outcljs + '/core.js'
    if ( not ( path.existsSync outcljscore ) )
      fs.writeFileSync outcljscore, @compiledCoreJS(), 'utf8'

  if @compiledNodejsJS.exists
    outcljsnodejs = outcljs + '/nodejs.js'
    if ( not ( path.existsSync outcljsnodejs ) )
      fs.writeFileSync outcljsnodejs, @compiledNodejsJS(), 'utf8'

  resolved = path.resolve ( path.normalize options.path )
  if ( not ( path.existsSync resolved ) )
    return ( callback ( new Error 'source path must exist' ), null )
  stats = fs.statSync resolved
  if ( stats.isDirectory() )
    cp = resolved
  else if ( stats.isFile() )
    cp = path.dirname resolved
  else
    return ( callback ( new Error 'source path must be a file or a directory' ), null )

  options.path = resolved
  options.classpath = cp

  builder options, cljscOptions, callback


ClojureScript.eval = (options, builder, callback, cljscOptions = ClojureScript.cljscOptions, javaOptions = ClojureScript.javaOptions) ->
  throw new Error 'ClojureScript.eval method is not yet implemented'


ClojureScript.run = (options, builder, callback, cljscOptions = ClojureScript.cljscOptions, javaOptions = ClojureScript.javaOptions) ->
  mainModule = require.main

  mainModule.filename = process.argv[1] =
    if options.path then fs.realpathSync(options.path) else '.'

  mainModule.moduleCache and= {}

  mainModule.paths = require('module')._nodeModulePaths path.dirname fs.realpathSync options.path

  # fairly certain this is the correct control flow, since this module
  # does not attempt to support the deprecated `require.registerExtension`
  # (coffee-script still supports it as of its version 1.3.1)
  if ( ( path.extname mainModule.filename ) is '.cljs' )
    if require.extensions
      mainModule._compile ClojureScript.build(options, builder, callback, cljscOptions, javaOptions), mainModule.filename
    else
      callback new Error 'missing require.extensions, can\'t proceed'
  else
    callback new Error 'ClojureScript.run method does not yet support compiling directly from a source string'

  # original coffee-script control flow, for reference:

  # if path.extname(mainModule.filename) isnt '.coffee' or require.extensions
  #   mainModule._compile compile(code, options), mainModule.filename
  # else
  #   mainModule._compile code, mainModule.filename

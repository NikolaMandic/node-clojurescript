ClojureScript.createServer = ->

  credPath = ( new ClojureScript.Tempfile ).path
  creds =
    username: uuid.v1()
    password: uuid.v1()

  fs.writeFileSync credPath, ( JSON.stringify creds ), 'utf8'
  fs.chmodSync credPath, '640'

  console.log 'Starting up, please wait...'

  # initial build, to prime the JVM and compiler
  iOptions  = { async: false, path: ( __dirname + '/support/cljs/detached_jvm_server_initial_build.cljs' ) }
  iBuilder  = ClojureScript.localBuilder
  iCallback = (err) -> if err then throw err
  ClojureScript.build iOptions, iBuilder, iCallback
  console.log clc.bold clc.cyan '\nInitial build completed, JVM and compiler are primed and ready!'

  server = restify.createServer()

  server.use restify.bodyParser mapParams: false
  server.use restify.authorizationParser()

  server.get '/creds/', (req, res, next) ->
    res.send { path: credPath }

  server.post '/build/', (req, res, next) ->
    if req.is 'application/json'

      if ( req.authorization.basic? and (( req.authorization.basic.username is creds.username ) and \
                                         ( req.authorization.basic.password is creds.password )) )
        options = req.body
        cljscOptions = options.cljscOptions
        delete options.cljscOptions

        callback = (err, js) ->
          if err
            res.send { err: err.message, js: null }
            console.log ( new Date ).toString(), ":", clc.bold clc.red 'build failed'
          else
            res.send { err: null, js: js }
            console.log ( new Date ).toString(), ":", clc.bold clc.green 'build successful'

        # ClojureScript.builder defaults to ClojureScript.localBuilder,
        # and this is not changed when the server option is invoked from
        # the command line; presently, all server builds will be done
        # synchronously, owing to an exception being thrown when async
        # calls to the clojure build method are attempted
        ClojureScript.builder options, cljscOptions, callback

      else
        res.send 401, ( new Error 'Unauthorized build request' )
        console.log ( new Date ).toString(), ":", clc.bold clc.magenta 'bad request'

    else
      res.send 415, ( new Error 'request Content-Type must be application/json' )
      console.log ( new Date ).toString(), ":", clc.bold clc.magenta 'bad request'

  server

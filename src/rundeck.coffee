# Description
#   Rundeck integration with hubot
#
# Dependencies:
#   "underscore": "^1.6.0"
#   "strftime": "^0.8.0"
#   "xml2js": "^0.4.1"
#
# Commands:
#   hubot rundeck projects [alias]                                   - Gets a list of the projects for the given server alias
#   hubut rundeck jobs '[project]' [alias]                           - Gets a list of all the jobs in the given project for the given server alias
#   hubot rundeck trigger '[job]' '[project]' [alias] [args]         - Triggers the given job for the given project
#   hubot rundeck status '[job]' '[project]' [alias]                 - Shows the current status for the latest execution of the given job
#   hubot rundeck show aliases                                       - shows the aliases for the list of rundeck instances
#   hubot rundeck add alias [alias name] [url] [authToken]           - sets the alias for a given url and authentication token
#   hubot rundeck clear alias [alias name]                           - removed the given alias
#
#rundeck show status of (.*) (?:in|for) (.*) (?:in|for) (.*)
# Notes:
#   The server must be a fqdn (with the port!) to get to rundeck
#
# Author:
#  Liam Bennett

_ = require('underscore')
sys = require 'sys' # Used for debugging
Parser = require('xml2js').Parser
_rundeckAliases = {}

class Rundeck
  constructor: (@robot, @url, @authToken) ->
    @logger = @robot.logger

    @baseUrl = "http://#{@url}/api/12"

    @headers =
      "Accept": "application/xml"
      "Content-Type": "application/xml"
      "X-Rundeck-Auth-Token": "#{@authToken}"

    @plainTextHeaders =
      "Accept": "text/plain"
      "Content-Type": "text/plain"
      "X-Rundeck-Auth-Token": "#{@authToken}"

  jobs: (project) -> new Jobs(@, project)
  projects: -> new Projects(@)
  executions: (job) -> new Executions(@, job)

  getOutput: (url, cb) ->
    @robot.http("#{@baseUrl}/#{url}").headers(@plainTextHeaders).get() (err, res, body) =>
      if err?
        @logger.err JSON.stringify(err)
      else
        cb body

  get: (url, cb) ->
    @logger.debug url
    parser = new Parser()

    @robot.http("#{@baseUrl}/#{url}").headers(@headers).get() (err, res, body) =>
      if err?
        @logger.error JSON.stringify(err)
      else
        parser.parseString body, (e, json) ->
          cb json

class Projects
  constructor: (@rundeck) ->
    @logger = @rundeck.logger

  list: (cb) ->
    projects = []
    @rundeck.get "projects", (results) ->
      for project in results.projects.project
        projects.push new Project(project)

      cb projects

class Project
  constructor: (data) ->
    @name = data.name[0]
    @description = data.description[0]

  formatList: ->
    "#{@name} - #{@description}"

class Jobs
  constructor: (@rundeck, @project) ->
    @logger = @rundeck.logger

  list: (cb) ->
    jobs = []
    @rundeck.get "project/#{@project}/jobs", (results) ->
      for job in results.jobs.job
        jobs.push new Job(job)

      cb jobs

  find: (name, cb) ->
    @list (jobs) =>
      job = _.findWhere jobs, { name: name }
      if job
        cb job
      else
        cb false

  run: (name, args, cb) ->
    @find name, (job) =>
      if job
        uri = "job/#{job.id}/run"
        if args?
          uri += "?argString=#{args}"

        @rundeck.get uri, (results) ->
          cb job, results
      else
        cb null, false

class Job
  constructor: (data) ->
    @id = data["$"].id
    @name = data.name[0]
    @description = data.description[0]
    @group = data.group[0]
    @project = data.project[0]

  formatList: ->
    "#{@name} - #{@description}"

class Executions
  constructor: (@rundeck, @job) ->
    @logger = @rundeck.logger

  list: (cb) ->
    executions = []
    @rundeck.get "job/#{@job.id}/executions", (results) ->
      for execution in results.result.executions[0].execution
        exec = new Execution(execution)
        executions.push exec

      cb executions

class Execution
  constructor: (@data) ->
    @id = data["$"].id
    @href = data["$"].href
    @status = data["$"].status

  formatList: ->
    "#{@id} - #{@status} - #{@href}"

module.exports = (robot) ->
  logger = robot.logger

  robot.brain.on 'loaded', ->
    if robot.brain.data.rundeck_aliases?
      _rundeckAliases = robot.brain.data.rundeck_aliases

  showAliases = (msg) ->
    if _rundeckAliases == null || Object.keys(_rundeckAliases).length == 0
      msg.send("I cannot find any rundeck system aliases")
    else
      for alias of _rundeckAliases
        msg.send("I found '#{alias}' as an alias for the system: #{_rundeckAliases[alias]['url']} - #{_rundeckAliases[alias]['authToken']}")

  clearAlias = (msg, alias) ->
    delete _rundeckAliases[alias]
    robot.brain.data.rundeck_aliases = _rundeckAliases
    msg.send("The rundeck system alias #{alias} has been removed")

  setAlias = (msg, alias, url, token) ->
    _rundeckAliases[alias] = { url: url, authToken: token }
    robot.brain.data.rundeck_aliases = _rundeckAliases
    msg.send("The rundeck system alias #{alias} for #{url} has been added to the brain")

  #hubot rundeck projects myrundeck-alias
  robot.respond /rundeck projects (.*)/i, (msg) ->
    if msg.message.user.id is robot.name
      return

    alias =  msg.match[1]
    url = _rundeckAliases[alias]['url']
    token = _rundeckAliases[alias]['authToken']


    if url == null || url == undefined || token == null || token == undefined
      msg.send "Do not recognise rundeck system alias #{alias}"
    else
      rundeck = new Rundeck(robot, url, token)
      rundeck.projects().list (projects) ->
        if projects.length > 0
          for project in projects
            msg.send project.formatList()
        else
          msg.send "No rundeck projects found."

  #hubot rundeck 'MyProject' jobs myrundeck-alias
  robot.respond /rundeck '(.*)' jobs (.*)/i, (msg) ->
    if msg.message.user.id is robot.name
      return

    project = msg.match[1]

    alias =  msg.match[2]
    url = _rundeckAliases[alias]['url']
    token = _rundeckAliases[alias]['authToken']

    if url == null || url == undefined || token == null || token == undefined
      msg.send "Do not recognise rundeck system alias #{alias}"
    else
      rundeck = new Rundeck(robot, url, token)
      rundeck.jobs(project).list (jobs) ->
        if jobs.length > 0
          for job in jobs
            msg.send job.formatList()
        else
          msg.send "No jobs found for rundeck #{project}"

  #hubot rundeck trigger 'my-job' 'MyProject' myrundeck-alias args:<optional args>
  robot.respond /rundeck trigger '(.*)'\s'(.*)'\s([\w]+)(?: args:)?(.*)/i, (msg) ->
    if msg.message.user.id is robot.name
      return

    name = msg.match[1]
    project = msg.match[2]
    args = msg.match[4]

    alias =  msg.match[3]
    url = _rundeckAliases[alias]['url']
    token = _rundeckAliases[alias]['authToken']

    if url == null || url == undefined || token == null || token == undefined
      msg.send "Do not recognise rundeck system alias #{alias}"
    else
      rundeck = new Rundeck(robot, url, token)
      rundeck.jobs(project).run name, args, (job, results) ->
        if job
          msg.send "Running job #{name}: #{results.result.executions[0].execution[0]['$'].href}"
        else
          msg.send "Could not execute rundeck job \"#{name}\"."

  robot.respond /rundeck status '(.*)' '(.*)' '(.*)'/i, (msg) ->
    if msg.message.user.id is robot.name
      return

    name = msg.match[1]
    project = msg.match[2]

    alias =  msg.match[3]
    url = _rundeckAliases[alias]['url']
    token = _rundeckAliases[alias]['authToken']

    if url == null || url == undefined || token == null || token == undefined
      msg.send "Do not recognise rundeck system alias #{alias}"
    else
      rundeck = new Rundeck(robot, url, token)
      rundeck.jobs(project).find name, (job) ->
        if job
          rundeck.executions(job).list (executions) ->
            if executions.length > 0
              keys = []
              for item in executions
                keys.push item.id
              key = keys.sort()[keys.length - 1]
              for execution in executions
                if execution.id == key
                  msg.send execution.formatList()
            else
              msg.send "No executions found"
        else
          msg.send "Could not find rundeck job \"#{name}\"."

  robot.respond /rundeck show aliases/i, (msg) ->
    if msg.message.user.id is robot.name
      return

    showAliases msg, (text) ->
      msg.send(text)

  robot.respond /rundeck add alias (.*) (.*) (.*)/i, (msg) ->
    if msg.message.user.id is robot.name
      return

    setAlias msg, msg.match[1], msg.match[2], msg.match[3], (text) ->
      msg.send(text)

  robot.respond /rundeck clear alias (.*)/i, (msg) ->
    if msg.message.user.id is robot.name
      return

    clearAlias msg, msg.match[1], (text) ->
      msg.send(text)

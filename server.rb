require 'sinatra'
require 'logger'
require 'json'
require 'openssl'
require 'octokit'
require 'jwt'
require 'time' # necessary to get the ISO 8601 representation of a Time object

set :port, 3000

class LabelSwitcherApp < Sinatra::Application
  # Notice that the private key must be in PEM format, but the newlines should be stripped and replaced with
  # the literal `\n`. This can be done in the terminal as such:
  # export GITHUB_PRIVATE_KEY=`awk '{printf "%s\\n", $0}' private-key.pem`
  PRIVATE_KEY = OpenSSL::PKey::RSA.new(ENV['GITHUB_PRIVATE_KEY'].gsub('\n', "\n")) # convert newlines

  # This verifies that the webhook is really coming from GH.
  WEBHOOK_SECRET = ENV['GITHUB_WEBHOOK_SECRET']

  # App identifier (an integer)
  APP_IDENTIFIER = ENV['GITHUB_APP_IDENTIFIER']

  # Labels
  REVIEW_REQUIRED_LABEL = 'review-required'.freeze
  CHANGES_REQUESTED_LABEL = 'changes-requested'.freeze
  WIP_LABEL = 'WIP'.freeze

  ########## Configure Sinatra
  #
  # Turn on verbose logging during development
  #

  configure :development do
    set :logging, Logger::DEBUG
  end

  ########## Before each request to our app
  before do
    payload = {
      # The time that this JWT was issued, _i.e._ now.
      iat: Time.now.to_i,

      # How long is the JWT good for (in seconds)?
      # Let's say it can be used for 10 minutes before it needs to be refreshed.
      # TODO we don't actually cache this token, we regenerate a new one every time!
      exp: Time.now.to_i + (10 * 60),

      # GitHub App's identifier number, so GitHub knows who issued the JWT, and know what permissions
      # this token has.
      iss: APP_IDENTIFIER
    }

    jwt = JWT.encode(payload, PRIVATE_KEY, 'RS256')

    @client ||= Octokit::Client.new(bearer_token: jwt)
  end

  ########## Events
  #
  # This is the webhook endpoint that GH will call with events, and hence where we will do our event handling
  #

  post '/' do
    request.body.rewind
    payload_raw = request.body.read # We need the raw text of the body to check the webhook signature
    begin
      payload = JSON.parse payload_raw
    rescue
      payload = {}
    end

    # Check X-Hub-Signature to confirm that this webhook was generated by GitHub, and not a malicious third party.
    # The signature comes in with header x-hub-signature, and looks like "sha1=123456"
    their_signature_header = request.env['HTTP_X_HUB_SIGNATURE'] || 'sha1='
    method, their_digest = their_signature_header.split('=')
    our_digest = OpenSSL::HMAC.hexdigest(method, WEBHOOK_SECRET, payload_raw)
    halt 401 unless their_digest == our_digest

    # Determine what kind of event this is, and take action as appropriate
    logger.debug "---- received event #{request.env['HTTP_X_GITHUB_EVENT']}"
    logger.debug "----         action #{payload['action']}" unless payload['action'].nil?

    authenticate_installation(payload)

    case request.env['HTTP_X_GITHUB_EVENT']
    when 'pull_request'
      case payload['action']
      when 'opened'
        handle_pull_request_opened_event(payload)
      when 'edited'
        handle_pull_request_edited_event(payload)
      when 'reopened'
        handle_pull_request_reopened_event(payload)
      when 'labeled'
        handle_pull_request_labeled_event(payload)
      when 'unlabeled'
        handle_pull_request_unlabeled_event(payload)
      end
    when 'pull_request_review'
      case payload['action']
      when 'submitted'
        handle_pull_request_review_submitted_event(payload)
      end
    end

    'ok' # have to return _something_ ;)
  end

  ########## Helpers
  #
  # These functions are going to help us do some tasks that we don't want clogging up the happy paths above
  #

  helpers do
    # authenticate app installation and initiate the bot_client
    def authenticate_installation(payload)
      # logger.debug payload
      installation_id = payload['installation']['id']
      installation_token = @client.create_app_installation_access_token(installation_id)[:token]
      @bot_client ||= Octokit::Client.new(bearer_token: installation_token)
    end

    # Adds the review-required label
    # Adds the status/WIP label if the PR has WIP on its title
    def handle_pull_request_opened_event(payload)
      # logger.debug payload
      repo = payload['repository']['full_name']
      pr_number = payload['pull_request']['number']
      labels = [REVIEW_REQUIRED_LABEL]
      labels << WIP_LABEL if (payload['pull_request']['title'].include?('[WIP]'))
      @bot_client.add_labels_to_an_issue(repo, pr_number, labels)
    end

    # Adds the status/WIP label if the PR has WIP on its title
    # Remove the status/WIP label if the PR doesnt have WIP on its title
    def handle_pull_request_edited_event(payload)
      # logger.debug payload
      repo = payload['repository']['full_name']
      pr_number = payload['pull_request']['number']
      current_labels = @bot_client.labels_for_issue(repo, pr_number).map(&:name)
      if payload['pull_request']['title'].include?('[WIP]')
        @bot_client.add_labels_to_an_issue(repo, pr_number, [WIP_LABEL]) unless current_labels.include?(WIP_LABEL)
      elsif current_labels.include?(WIP_LABEL)
        @bot_client.remove_label(repo, pr_number, WIP_LABEL)
      end
    end

    # Adds the status/WIP label if the PR has WIP on its title
    def handle_pull_request_reopened_event(payload)
      # logger.debug payload
      repo = payload['repository']['full_name']
      pr_number = payload['pull_request']['number']
      @bot_client.add_labels_to_an_issue(repo, pr_number, [WIP_LABEL]) if payload['pull_request']['title'].include?('[WIP]')
    end

    # Adds the changes-requested label (and removed review-required) if the reviewer asked for changes
    def handle_pull_request_review_submitted_event(payload)
      # logger.debug payload
      repo = payload['repository']['full_name']
      pr_number = payload['pull_request']['number']
      current_labels = @bot_client.labels_for_issue(repo, pr_number).map(&:name)
      return unless payload['review']['state'] == 'changes_requested'

      @bot_client.add_labels_to_an_issue(repo, pr_number, [CHANGES_REQUESTED_LABEL])
      @bot_client.remove_label(repo, pr_number, REVIEW_REQUIRED_LABEL) if current_labels.include?(REVIEW_REQUIRED_LABEL)
    end

    # Adds [WIP] to the PR title if the user added the WIP label and forgot to write [WIP]
    def handle_pull_request_labeled_event(payload)
      # logger.debug payload
      repo = payload['repository']['full_name']
      pr_number = payload['pull_request']['number']
      if payload['label']['name'] == WIP_LABEL && !payload['pull_request']['title'].include?('[WIP]')
        @bot_client.update_pull_request(repo, pr_number, title: "[WIP] #{payload['pull_request']['title']}")
      end
    end

    # Removes [WIP] from the PR title if the user removed the WIP label
    def handle_pull_request_unlabeled_event(payload)
      # logger.debug payload
      repo = payload['repository']['full_name']
      pr_number = payload['pull_request']['number']
      if payload['label']['name'] == WIP_LABEL && payload['pull_request']['title'].include?('[WIP]')
        @bot_client.update_pull_request(repo, pr_number, title: payload['pull_request']['title'].gsub('[WIP] ', ''))
      end
    end
  end

  # Finally some logic to let us run this server directly from the commandline, or with Rack
  # $0 is the executed file
  # __FILE__ is the current file
  # If they are the same—that is, we are running this file directly, call the Sinatra run method
  run! if __FILE__ == $0
end

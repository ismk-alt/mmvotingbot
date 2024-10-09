require 'sinatra/base'
require 'json'
require_relative 'services/vote_service'

class MyApp < Sinatra::Base
  post '/vote' do
    begin
      request_payload = JSON.parse(request.body.read)
      puts "Webhook received: #{request_payload}"

      response = VoteService.new.process_vote(request_payload)
      
      status 200
      response
    rescue JSON::ParserError => e
      puts "JSON parsing error: #{e.message}"
      halt 400, 'Invalid JSON format'
    rescue StandardError => e
      puts "An error occurred: #{e.message}"
      halt 500, 'Internal Server Error'
    end
  end

  # Запуск приложения
  run! if app_file == $0
end

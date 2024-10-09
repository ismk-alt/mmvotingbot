# vote_routes.rb
require 'sinatra'
require_relative '../services/vote_service'
require_relative '../utils/mattermost_api'  # Подключаем MattermostApi

# Sinatra route for handling voting
post '/vote' do
  begin
    request_payload = JSON.parse(request.body.read)

    # Логируем полученный вебхук
    puts "Webhook received in /vote: #{request_payload}"

    # Валидация токена вебхука
    token = request_payload['token']&.strip
    expected_token = ENV['OUTGOING_WEBHOOK_TOKEN']&.strip

    unless token && token == expected_token
      puts "Invalid token in /vote: received='#{token}', expected='#{expected_token}'"
      halt 403, 'Invalid token'
    end

    # Передача данных в VoteService для обработки голосования
    response = VoteService.new.process_vote(request_payload)
    
    status 200
    response
  rescue JSON::ParserError => e
    puts "JSON parsing error in /vote: #{e.message}"
    halt 400, 'Invalid JSON format'
  rescue StandardError => e
    puts "An error occurred in /vote: #{e.message}"
    halt 500, 'Internal Server Error'
  end
end

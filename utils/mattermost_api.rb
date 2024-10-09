# mattermost_api.rb
require 'dotenv/load'
require 'net/http'
require 'json'

class MattermostApi
  # Метод для отправки сообщения о голосовании с селектом и кнопкой голосования
  def self.send_vote_message(item, channel_id)
    message = {
      "channel_id" => channel_id,
      "message" => "Голосование за номинацию: #{item}",
      "props" => {
        "attachments" => [
          {
            "text" => "Выберите сотрудника для номинации: #{item}",
            "actions" => [
              {
                "name" => "employee_select",
                "integration" => {
                  "url" => ENV['INCOMING_WEBHOOK_URL'],
                  "context" => {
                    "action" => "vote",
                    "item" => item
                  }
                },
                "type" => "select",
                "data_source" => "users"  # Позволяет выбирать пользователей из списка Mattermost
              },
              {
                "name" => "Проголосовать",
                "integration" => {
                  "url" => ENV['OUTGOING_WEBHOOK_URL'],
                  "context" => {
                    "action" => "submit_vote",
                    "item" => item,
                    "selected_option" => "selected_option"
                  }
                },
                "type" => "button",
                "data_source" => "users",
                "style" => "primary",
                "disabled" => false
              }
            ]
          }
        ]
      }
    }
  
    uri = URI("#{ENV['MATTERMOST_API_URL']}/api/v4/posts")
    header = { 'Content-Type' => 'application/json', 'Authorization' => "Bearer #{ENV['BOT_ACCESS_TOKEN']}" }
    body = message.to_json
  
    send_post_request(uri, header, body)
  end
  
  

  # Метод для обновления кнопки после голосования
  def self.update_vote_button(item, user, post_id)
    message = {
      "id" => post_id,  # Добавляем ID сообщения в тело запроса
      "message" => "",
      "props" => {
        "attachments" => [
          {
            "text" => "Голосование за номинацию: #{item}",
            "actions" => [
              {
                "name" => "Проголосовать",
                "type" => "button",
                "style" => "default",
                "disabled" => true,  # Делаем кнопку неактивной
                "text" => "Вы проголосовали"
              }
            ]
          }
        ]
      }
    }
  
    # Используем правильный путь для обновления сообщения
    uri = URI("#{ENV['MATTERMOST_API_URL']}/api/v4/posts/#{post_id}")
    header = { 'Content-Type' => 'application/json', 'Authorization' => "Bearer #{ENV['BOT_ACCESS_TOKEN']}" }
    body = message.to_json
  
    # Используем PUT вместо PATCH
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    request = Net::HTTP::Put.new(uri.request_uri, header)
    request.body = body
    response = http.request(request)
    puts "Response from Mattermost: #{response.code} - #{response.body}"
    response
  end

  def self.send_message_to_mattermost(message, root_id = nil, channel_id = nil)
    payload = {
      "channel_id" => channel_id,
      "message" => message,
      "root_id" => root_id
    }

    uri = URI("#{ENV['MATTERMOST_API_URL']}/api/v4/posts")
    header = { 'Content-Type' => 'application/json', 'Authorization' => "Bearer #{ENV['BOT_ACCESS_TOKEN']}" }
    body = payload.to_json

    send_post_request(uri, header, body)
  end

  # Вспомогательный метод для отправки POST-запроса
  def self.send_post_request(uri, header, body)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    request = Net::HTTP::Post.new(uri.request_uri, header)
    request.body = body
    response = http.request(request)
    puts "Response from Mattermost: #{response.code} - #{response.body}"
    response
  end
end





#vote_routes
require 'sinatra'
require_relative '../services/vote_service'

# Sinatra route for handling voting
post '/vote' do
  begin
    request_payload = JSON.parse(request.body.read)

    # Логируем полученный вебхук
    puts "Webhook received: #{request_payload}"

    # Валидация токена вебхука
    token = request_payload['token']&.strip
    expected_token = OUTGOING_WEBHOOK_TOKEN&.strip

    unless token && token == expected_token
      puts "Invalid token: received='#{token}', expected='#{expected_token}'"
      halt 403, 'Invalid token'
    end

    # Передача данных в VoteService для обработки голосования
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
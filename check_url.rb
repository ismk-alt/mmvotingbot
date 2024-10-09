require 'net/http'
require 'json'

class MattermostApi
  # Метод для отправки сообщения в указанный канал
  def self.send_vote_message(item, user_name, channel_id)
    message = {
      "channel_id" => channel_id,
      "message" => "Голосование за номинацию: #{item}",
      "props" => {
        "attachments" => [
          {
            "text" => "Голосование за номинацию: #{item}",
            "actions" => [
              {
                "name" => "Выберите сотрудника",
                "integration" => {
                  "url" => ENV['INCOMING_WEBHOOK_URL'],
                  "context" => {
                    "action" => "vote",
                    "item" => item
                  }
                },
                "type" => "select",
                "data_source" => "users",
                "options" => [
                  {
                    "text" => "@#{user_name}",
                    "value" => user_name
                  }
                ]
              },
              {
                "name" => "Проголосовать",
                "integration" => {
                  "url" => ENV['INCOMING_WEBHOOK_URL'],
                  "context" => {
                    "action" => "submit_vote",
                    "item" => item
                  }
                },
                "type" => "button",
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
  

  # Метод для отправки POST-запроса
  def self.send_post_request(uri, header, body)
    http = Net::HTTP.new(uri.host, uri.port)
    request = Net::HTTP::Post.new(uri.request_uri, header)
    request.body = body
    response = http.request(request)
    puts "Response from Mattermost: #{response.code} - #{response.body}"
    response
  end
end

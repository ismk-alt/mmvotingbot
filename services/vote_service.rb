# services/vote_service.rb
require_relative '../models/vote_model'
require_relative '../utils/mattermost_api'


class VoteService
  def process_vote(request_payload)
    command = request_payload['text']&.strip
    user = request_payload['user_name']
    action = request_payload.dig('context', 'action')
    item = request_payload.dig('context', 'item')
    selected_user = request_payload.dig('data', 'values', 'employee_select') || request_payload.dig('context', 'selected_user')
    channel_id = request_payload['channel_id']
    post_id = request_payload['post_id']

    puts "Processing action: #{action}, item: #{item}, user: #{user}, selected_user: #{selected_user}"

    if action == 'vote' && selected_user
      # Сохраняем выбранного сотрудника через VoteModel
      VoteModel.save_selected_user(post_id, selected_user)
      return "Вы выбрали: #{selected_user}"
    elsif action == 'submit_vote'
      # Получаем сохранённого выбранного сотрудника через VoteModel
      selected_user = VoteModel.get_selected_user(post_id) || "Не выбран"
      puts "Submitting vote for: #{selected_user}"
      return register_vote(user, item, selected_user, channel_id, post_id)
    else
      handle_command(command, user, channel_id)
    end
  end

  def handle_command(command, user, channel_id)
    case command
    when /^!start_vote\s*(.*)/
      items = command.split("\n")[1..-1]  # Извлекаем номинации из команды
      if items.empty?
        return 'Ошибка: Вы должны предоставить хотя бы одну номинацию для голосования.'
      end
      VoteModel.start_vote(items, user, channel_id)
      'Голосование начато.'
    when '!end_vote'
      VoteModel.end_vote
      'Голосование завершено.'
    else
      'Неизвестная команда. Пожалуйста, используйте !start_vote или !end_vote.'
    end
  end

  def register_vote(user, item, selected_user, channel_id, post_id)
    response_message = VoteModel.register_vote(user, item, selected_user)

    if response_message
      MattermostApi.send_message_to_mattermost(response_message, nil, channel_id)
      MattermostApi.update_vote_button(item, selected_user, post_id)
    end

    response_message
  end
end


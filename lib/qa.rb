module ::QuestionAnswer
  class Engine < ::Rails::Engine
    engine_name 'question_answer'
    isolate_namespace QuestionAnswer
  end
end

QuestionAnswer::Engine.routes.draw do
  resource :vote
  get 'voters' => 'votes#voters'
end

Discourse::Application.routes.append do
  mount ::QuestionAnswer::Engine, at: 'qa'
end

require_dependency 'post_action_user_serializer'
class QuestionAnswer::VoterSerializer < ::PostActionUserSerializer
  def post_url
    nil
  end
end

Voter = Struct.new(:user)

require_dependency 'application_controller'
class QuestionAnswer::VotesController < ::ApplicationController
  before_action :ensure_logged_in
  before_action :find_vote_post
  before_action :find_vote_user, only: [:create, :destroy]
  before_action :ensure_qa_enabled, only: [:create, :destroy]
  before_action :ensure_can_act, only: [:create, :destroy]

  def create
    if QuestionAnswer::Vote.vote(@post, @user, vote_args)
      render json: success_json.merge(
        vote_count: @post.vote_count
      )
    else
      render json: failed_json, status: 422
    end
  end

  def destroy
    if QuestionAnswer::Vote.vote(@post, @user, vote_args)
      render json: success_json.merge(
        vote_count: @post.vote_count
      )
    else
      render json: failed_json, status: 422
    end
  end

  def voters
    voters = []

    if @post.voted.any?
      @post.voted.each do |user_id|
        if user = User.find_by(id: user_id)
          voters.push(Voter.new(user))
        end
      end
    end

    render_json_dump(voters: serialize_data(voters, QuestionAnswer::VoterSerializer))
  end

  private

  def vote_params
    params.require(:vote).permit(:post_id, :user_id, :direction)
  end

  def vote_args
    {
      direction: vote_params[:direction],
      action: self.action_name
    }
  end

  def find_vote_post
    if params[:vote].present?
      post_id = vote_params[:post_id]
    else
      params.require(:post_id)
      post_id = params[:post_id]
    end

    if post = Post.find_by(id: post_id)
     @post = post
    else
     raise Discourse::NotFound
    end
  end

  def find_vote_user
    if vote_params[:user_id] && user = User.find_by(id: vote_params[:user_id])
      @user = user
    else
      raise Discourse::NotFound
    end
  end

  def ensure_qa_enabled
    Topic.qa_enabled(@post.topic)
  end

  def ensure_can_act
    if Topic.voted(@post.topic, @user)
      if self.action_name === QuestionAnswer::Vote::CREATE
       raise Discourse::InvalidAccess.new, I18n.t('vote.error.alread_voted')
      end

      if self.action_name === QuestionAnswer::Vote::DESTROY && !QuestionAnswer::Vote.can_undo(@post, @user)
       raise Discourse::InvalidAccess.new, I18n.t('vote.error.undo_vote_action_window',
         minutes: SiteSetting.qa_undo_vote_action_window
       )
      end
    elsif self.action_name === QuestionAnswer::Vote::DESTROY
      raise Discourse::InvalidAccess.new, I18n.t('vote.error.user_has_not_voted')
    end
  end
end

class QuestionAnswer::Vote
  CREATE = 'create'
  DESTROY = 'destroy'
  UP = 'up'
  DOWN = 'down'

  def self.vote(post, user, args)
    modifier = 0

    if args[:direction] === UP
      modifier = args[:action] === CREATE ? 1 : -1
    end

    post.custom_fields['vote_count'] = post.vote_count + modifier

    voted = post.voted

    if args[:direction] === UP
      if args[:action] === CREATE
        voted.push(user.id)
      elsif args[:action] === DESTROY
        voted.delete(user.id)
      end
    end

    post.custom_fields['voted'] = voted

    votes = post.vote_history

    votes.push(
      direction: args[:direction],
      action: args[:action],
      user_id: user.id,
      created_at: Time.now
    )

    post.custom_fields['vote_history'] = votes.to_json

    if post.save_custom_fields(true)
      Topic.update_vote_order(post.topic)
      post.publish_change_to_clients! :acted

      true
    else
      false
    end
  end

  def self.can_undo(post, user)
    window = SiteSetting.qa_undo_vote_action_window.to_i
    window === 0 || post.last_voted(user.id).to_i > window.minutes.ago.to_i
  end
end

#-- encoding: UTF-8
#-- copyright
# ChiliProject is a project management system.
#
# Copyright (C) 2010-2011 the ChiliProject Team
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# See doc/COPYRIGHT.rdoc for more details.
#++

require "digest/sha1"

class User < Principal
  include Redmine::SafeAttributes

  # Account statuses
  STATUS_BUILTIN    = 0
  STATUS_ACTIVE     = 1
  STATUS_REGISTERED = 2
  STATUS_LOCKED     = 3

  USER_FORMATS_STRUCTURE = {
    :firstname_lastname => [:firstname, :lastname],
    :firstname => [:firstname],
    :lastname_firstname => [:lastname, :firstname],
    :lastname_coma_firstname => [:lastname, :firstname],
    :username => [:login]
  }

  def self.user_format_structure_to_format(key, delimiter = " ")
    USER_FORMATS_STRUCTURE[key].map{|elem| "\#{#{elem.to_s}}"}.join(delimiter)
  end

  USER_FORMATS = {
    :firstname_lastname =>      User.user_format_structure_to_format(:firstname_lastname, " "),
    :firstname =>               User.user_format_structure_to_format(:firstname),
    :lastname_firstname =>      User.user_format_structure_to_format(:lastname_firstname, " "),
    :lastname_coma_firstname => User.user_format_structure_to_format(:lastname_coma_firstname, ", "),
    :username =>                User.user_format_structure_to_format(:username)
  }

  MAIL_NOTIFICATION_OPTIONS = [
    ['all', :label_user_mail_option_all],
    ['selected', :label_user_mail_option_selected],
    ['only_my_events', :label_user_mail_option_only_my_events],
    ['only_assigned', :label_user_mail_option_only_assigned],
    ['only_owner', :label_user_mail_option_only_owner],
    ['none', :label_user_mail_option_none]
  ]

  USER_DELETION_JOURNAL_BUCKET_SIZE = 1000;

  has_many :group_users
  has_many :groups, :through => :group_users,
                    :after_add => Proc.new {|user, group| group.user_added(user)},
                    :after_remove => Proc.new {|user, group| group.user_removed(user)}
  has_many :issue_categories, :foreign_key => 'assigned_to_id',
                              :dependent => :nullify
  has_many :assigned_issues, :foreign_key => 'assigned_to_id',
                             :class_name => 'Issue',
                             :dependent => :nullify
  has_many :watches, :class_name => 'Watcher',
                     :dependent => :delete_all
  has_many :changesets, :dependent => :nullify
  has_one :preference, :dependent => :destroy, :class_name => 'UserPreference'
  has_one :rss_token, :dependent => :destroy, :class_name => 'Token', :conditions => "action='feeds'"
  has_one :api_token, :dependent => :destroy, :class_name => 'Token', :conditions => "action='api'"
  belongs_to :auth_source

  # TODO: this is from Principal. the inheritance doesn't work correctly
  # note: it doesn't fail in development mode
  # see: https://github.com/rails/rails/issues/3847
  has_many :members, :foreign_key => 'user_id', :dependent => :destroy
  has_many :memberships, :class_name => 'Member', :foreign_key => 'user_id', :include => [ :project, :roles ], :conditions => "#{Project.table_name}.status=#{Project::STATUS_ACTIVE}", :order => "#{Project.table_name}.name"
  has_many :projects, :through => :memberships

  # Active non-anonymous users scope
  scope :active, :conditions => "#{User.table_name}.status = #{STATUS_ACTIVE}"
  scope :active_or_registered, :conditions => "#{User.table_name}.status = #{STATUS_ACTIVE} or #{User.table_name}.status = #{STATUS_REGISTERED}"

  acts_as_customizable

  attr_accessor :password, :password_confirmation
  attr_accessor :last_before_login_on
  # Prevents unauthorized assignments
  attr_protected :login, :admin, :password, :password_confirmation, :hashed_password

  validates_presence_of :login,
                        :firstname,
                        :lastname,
                        :mail,
                        :unless => Proc.new { |user| user.is_a?(AnonymousUser) || user.is_a?(DeletedUser) }

  validates_uniqueness_of :login, :if => Proc.new { |user| !user.login.blank? }, :case_sensitive => false
  validates_uniqueness_of :mail, :allow_blank => true, :case_sensitive => false
  # Login must contain lettres, numbers, underscores only
  validates_format_of :login, :with => /^[a-z0-9_\-@\.]*$/i
  validates_length_of :login, :maximum => 256
  validates_length_of :firstname, :lastname, :maximum => 30
  validates_format_of :mail, :with => /^([^@\s]+)@((?:[-a-z0-9]+\.)+[a-z]{2,})$/i, :allow_blank => true
  validates_length_of :mail, :maximum => 60, :allow_nil => true
  validates_confirmation_of :password, :allow_nil => true
  validates_inclusion_of :mail_notification, :in => MAIL_NOTIFICATION_OPTIONS.collect(&:first), :allow_blank => true

  validate :password_not_too_short

  before_save :encrypt_password
  before_create :sanitize_mail_notification_setting
  before_destroy :delete_associated_public_queries
  before_destroy :reassign_associated

  scope :in_group, lambda {|group|
    group_id = group.is_a?(Group) ? group.id : group.to_i
    { :conditions => ["#{User.table_name}.id IN (SELECT gu.user_id FROM #{table_name_prefix}group_users#{table_name_suffix} gu WHERE gu.group_id = ?)", group_id] }
  }
  scope :not_in_group, lambda {|group|
    group_id = group.is_a?(Group) ? group.id : group.to_i
    { :conditions => ["#{User.table_name}.id NOT IN (SELECT gu.user_id FROM #{table_name_prefix}group_users#{table_name_suffix} gu WHERE gu.group_id = ?)", group_id] }
  }
  scope :admin, :conditions => { :admin => true }

  def sanitize_mail_notification_setting
    self.mail_notification = Setting.default_notification_option if self.mail_notification.blank?
    true
  end

  # update hashed_password if password was set
  def encrypt_password
    if self.password && self.auth_source_id.blank?
      salt_password(password)
    end
  end

  def reload(*args)
    @name = nil
    @projects_by_role = nil
    super
  end

  def mail=(arg)
    write_attribute(:mail, arg.to_s.strip)
  end

  def identity_url=(url)
    if url.blank?
      write_attribute(:identity_url, '')
    else
      begin
        write_attribute(:identity_url, OpenIdAuthentication.normalize_identifier(url))
      rescue OpenIdAuthentication::InvalidOpenId
        # Invlaid url, don't save
      end
    end
    self.read_attribute(:identity_url)
  end

  def self.register_allowance_evaluator(filter)
    self.registered_allowance_evaluators ||= []

    registered_allowance_evaluators << filter
  end

  # replace by class_attribute when on rails 3.x
  class_eval do
    def self.registered_allowance_evaluators() nil end
    def self.registered_allowance_evaluators=(val)
      singleton_class.class_eval do
        define_method(:registered_allowance_evaluators) do
          val
        end
      end
    end
  end

  register_allowance_evaluator ChiliProject::PrincipalAllowanceEvaluator::Default

  # Returns the user that matches provided login and password, or nil
  def self.try_to_login(login, password)
    # Make sure no one can sign in with an empty password
    return nil if password.to_s.empty?
    user = find_by_login(login)
    if user
      # user is already in local database
      return nil if !user.active?
      if user.auth_source
        # user has an external authentication method
        return nil unless user.auth_source.authenticate(login, password)
      else
        # authentication with local password
        return nil unless user.check_password?(password)
      end
    else
      # user is not yet registered, try to authenticate with available sources
      attrs = AuthSource.authenticate(login, password)
      if attrs
        # login is both safe and protected in chilis core code
        # in case it's intentional we keep it that way
        user = new(attrs.except(:login))
        user.login = login
        user.language = Setting.default_language
        if user.save
          user.reload
          logger.info("User '#{user.login}' created from external auth source: #{user.auth_source.type} - #{user.auth_source.name}") if logger && user.auth_source
        end
      end
    end
    user.update_attribute(:last_login_on, Time.now) if user && !user.new_record?
    user
  rescue => text
    raise text
  end

  # Returns the user who matches the given autologin +key+ or nil
  def self.try_to_autologin(key)
    tokens = Token.find_all_by_action_and_value('autologin', key)
    # Make sure there's only 1 token that matches the key
    if tokens.size == 1
      token = tokens.first
      if (token.created_on > Setting.autologin.to_i.day.ago) && token.user && token.user.active?
        token.user.update_attribute(:last_login_on, Time.now)
        token.user
      end
    end
  end

  # Return user's full name for display
  def name(formatter = nil)
    if formatter
      eval('"' + (USER_FORMATS[formatter] || USER_FORMATS[:firstname_lastname]) + '"')
    else
      @name ||= eval('"' + (USER_FORMATS[Setting.user_format] || USER_FORMATS[:firstname_lastname]) + '"')
    end
  end

  def active?
    self.status == STATUS_ACTIVE
  end

  def registered?
    self.status == STATUS_REGISTERED
  end

  def locked?
    self.status == STATUS_LOCKED
  end

  def activate
    self.status = STATUS_ACTIVE
  end

  def register
    self.status = STATUS_REGISTERED
  end

  def lock
    self.status = STATUS_LOCKED
  end

  def activate!
    update_attribute(:status, STATUS_ACTIVE)
  end

  def register!
    update_attribute(:status, STATUS_REGISTERED)
  end

  def lock!
    update_attribute(:status, STATUS_LOCKED)
  end

  # Returns true if +clear_password+ is the correct user's password, otherwise false
  def check_password?(clear_password)
    if auth_source_id.present?
      auth_source.authenticate(self.login, clear_password)
    else
      User.hash_password("#{salt}#{User.hash_password clear_password}") == hashed_password
    end
  end

  # Generates a random salt and computes hashed_password for +clear_password+
  # The hashed password is stored in the following form: SHA1(salt + SHA1(password))
  def salt_password(clear_password)
    self.salt = User.generate_salt
    self.hashed_password = User.hash_password("#{salt}#{User.hash_password clear_password}")
  end

  # Does the backend storage allow this user to change their password?
  def change_password_allowed?
    return true if auth_source_id.blank?
    return auth_source.allow_password_changes?
  end

  # Generate and set a random password.  Useful for automated user creation
  # Based on Token#generate_token_value
  #
  def random_password
    chars = ("a".."z").to_a + ("A".."Z").to_a + ("0".."9").to_a
    password = ''
    40.times { |i| password << chars[rand(chars.size-1)] }
    self.password = password
    self.password_confirmation = password
    self
  end

  def pref
    preference || build_preference
  end

  def time_zone
    @time_zone ||= (self.pref.time_zone.blank? ? nil : ActiveSupport::TimeZone[self.pref.time_zone])
  end

  def impaired=(value)
    self.pref.update_attribute(:impaired, !!value)
    !!value
  end

  def impaired
    anonymous? || !!self.pref.impaired
  end

  def impaired?
    impaired
  end

  def wants_comments_in_reverse_order?
    self.pref[:comments_sorting] == 'desc'
  end

  # Return user's RSS key (a 40 chars long string), used to access feeds
  def rss_key
    token = self.rss_token || Token.create(:user => self, :action => 'feeds')
    token.value
  end

  # Return user's API key (a 40 chars long string), used to access the API
  def api_key
    token = self.api_token || self.create_api_token(:action => 'api')
    token.value
  end

  # Return an array of project ids for which the user has explicitly turned mail notifications on
  def notified_projects_ids
    @notified_projects_ids ||= memberships.select {|m| m.mail_notification?}.collect(&:project_id)
  end

  def notified_project_ids=(ids)
    Member.update_all("mail_notification = #{connection.quoted_false}", ['user_id = ?', id])
    Member.update_all("mail_notification = #{connection.quoted_true}", ['user_id = ? AND project_id IN (?)', id, ids]) if ids && !ids.empty?
    @notified_projects_ids = nil
    notified_projects_ids
  end

  def valid_notification_options
    self.class.valid_notification_options(self)
  end

  # Only users that belong to more than 1 project can select projects for which they are notified
  def self.valid_notification_options(user=nil)
    # Note that @user.membership.size would fail since AR ignores
    # :include association option when doing a count
    if user.nil? || user.memberships.length < 1
      MAIL_NOTIFICATION_OPTIONS.reject {|option| option.first == 'selected'}
    else
      MAIL_NOTIFICATION_OPTIONS
    end
  end

  # Find a user account by matching the exact login and then a case-insensitive
  # version.  Exact matches will be given priority.
  def self.find_by_login(login)
    # force string comparison to be case sensitive on MySQL
    type_cast = (ChiliProject::Database.mysql?) ? 'BINARY' : ''
    # First look for an exact match
    user = first(:conditions => ["#{type_cast} login = ?", login])
    # Fail over to case-insensitive if none was found
    user ||= first(:conditions => ["#{type_cast} LOWER(login) = ?", login.to_s.downcase])
  end

  def self.find_by_rss_key(key)
    token = Token.find_by_value(key)
    token && token.user.active? ? token.user : nil
  end

  def self.find_by_api_key(key)
    token = Token.find_by_action_and_value('api', key)
    token && token.user.active? ? token.user : nil
  end

  # Makes find_by_mail case-insensitive
  def self.find_by_mail(mail)
    find(:first, :conditions => ["LOWER(mail) = ?", mail.to_s.downcase])
  end

  def self.find_all_by_mails(mails)
    find(:all, :conditions => ['LOWER(mail) IN (?)', mails])
  end

  def to_s
    name
  end

  # Returns the current day according to user's time zone
  def today
    if time_zone.nil?
      Date.today
    else
      Time.now.in_time_zone(time_zone).to_date
    end
  end

  def logged?
    true
  end

  def anonymous?
    !logged?
  end

  # Return user's roles for project
  def roles_for_project(project)
    roles = []
    # No role on archived projects
    return roles unless project && project.active?
    if logged?
      # Find project membership
      membership = memberships.detect {|m| m.project_id == project.id}
      if membership
        roles = membership.roles
      else
        @role_non_member ||= Role.non_member
        roles << @role_non_member
      end
    else
      @role_anonymous ||= Role.anonymous
      roles << @role_anonymous
    end
    roles
  end

  # Cheap version of Project.visible.count
  def number_of_known_projects
    if admin?
      Project.count
    else
      Project.public.count + memberships.size
    end
  end

  # Return true if the user is a member of project
  def member_of?(project)
    roles_for_project(project).any?(&:member?)
  end

  # Returns a hash of user's projects grouped by roles
  def projects_by_role
    return @projects_by_role if @projects_by_role

    @projects_by_role = Hash.new {|h,k| h[k]=[]}
    memberships.each do |membership|
      membership.roles.each do |role|
        @projects_by_role[role] << membership.project if membership.project
      end
    end
    @projects_by_role.each do |role, projects|
      projects.uniq!
    end

    @projects_by_role
  end

  # Return true if the user is allowed to do the specified action on a specific context
  # Action can be:
  # * a parameter-like Hash (eg. :controller => '/projects', :action => 'edit')
  # * a permission Symbol (eg. :edit_project)
  # Context can be:
  # * a project : returns true if user is allowed to do the specified action on this project
  # * a group of projects : returns true if user is allowed on every project
  # * nil with options[:global] set : check if user has at least one role allowed for this action,
  #   or falls back to Non Member / Anonymous permissions depending if the user is logged
  def allowed_to?(action, context, options={})
    if action.is_a?(Hash) && action[:controller] && action[:controller].to_s.starts_with?("/")
      action = action.dup
      action[:controller] = action[:controller][1..-1]
    end

    if context.is_a?(Project)
      allowed_to_in_project?(action, context, options)
    elsif context.is_a?(Array)
      # Authorize if user is authorized on every element of the array
      context.present? && context.all? do |project|
        allowed_to?(action,project,options)
      end
    elsif options[:global]
      allowed_to_globally?(action, options)
    else
      false
    end
  end

  def allowed_to_in_project?(action, project, options = {})
    initialize_allowance_evaluators

    # No action allowed on archived projects
    return false unless project.active?
    # No action allowed on disabled modules
    return false unless project.allows_to?(action)
    # Admin users are authorized for anything else
    return true if admin?

    candidates_for_project_allowance(project).any? do |candidate|
      denied = @registered_allowance_evaluators.any? do |filter|
        filter.denied_for_project? candidate, action, project, options
      end

      !denied && @registered_allowance_evaluators.any? do |filter|
        filter.granted_for_project? candidate, action, project, options
      end
    end
  end

  # Is the user allowed to do the specified action on any project?
  # See allowed_to? for the actions and valid options.
  def allowed_to_globally?(action, options = {})
    # Admin users are always authorized
    return true if admin?

    initialize_allowance_evaluators

    # authorize if user has at least one membership granting this permission
    candidates_for_global_allowance.any? do |candidate|
      denied = @registered_allowance_evaluators.any? do |evaluator|
        evaluator.denied_for_global? candidate, action, options
      end


      !denied && @registered_allowance_evaluators.any? do |evaluator|
        evaluator.granted_for_global? candidate, action, options
      end
    end
  end

  safe_attributes 'firstname', 'lastname', 'mail', 'mail_notification', 'language',
                  'custom_field_values', 'custom_fields', 'identity_url'

  safe_attributes 'status', 'auth_source_id',
    :if => lambda {|user, current_user| current_user.admin?}

  safe_attributes 'group_ids',
    :if => lambda {|user, current_user| current_user.admin? && !user.new_record?}

  # Utility method to help check if a user should be notified about an
  # event.
  #
  # TODO: only supports Issue events currently
  def notify_about?(object)
    case mail_notification
    when 'all'
      true
    when 'selected'
      # user receives notifications for created/assigned issues on unselected projects
      if object.is_a?(Issue) && (object.author == self || object.assigned_to == self)
        true
      else
        false
      end
    when 'none'
      false
    when 'only_my_events'
      if object.is_a?(Issue) && (object.author == self || object.assigned_to == self)
        true
      else
        false
      end
    when 'only_assigned'
      if object.is_a?(Issue) && object.assigned_to == self
        true
      else
        false
      end
    when 'only_owner'
      if object.is_a?(Issue) && object.author == self
        true
      else
        false
      end
    else
      false
    end
  end

  def self.current=(user)
    @current_user = user
  end

  def self.current
    @current_user ||= User.anonymous
  end

  # Returns the anonymous user.  If the anonymous user does not exist, it is created.  There can be only
  # one anonymous user per database.
  def self.anonymous
    anonymous_user = AnonymousUser.find(:first)
    if anonymous_user.nil?
      (anonymous_user = AnonymousUser.new.tap do |u|
        u.lastname = 'Anonymous'
        u.login = ''
        u.firstname = ''
        u.mail = ''
        u.status = 0
      end).save
      raise 'Unable to create the anonymous user.' if anonymous_user.new_record?
    end
    anonymous_user
  end

  # Salts all existing unsalted passwords
  # It changes password storage scheme from SHA1(password) to SHA1(salt + SHA1(password))
  # This method is used in the SaltPasswords migration and is to be kept as is
  def self.salt_unsalted_passwords!
    transaction do
      User.find_each(:conditions => "salt IS NULL OR salt = ''") do |user|
        next if user.hashed_password.blank?
        salt = User.generate_salt
        hashed_password = User.hash_password("#{salt}#{user.hashed_password}")
        User.update_all("salt = '#{salt}', hashed_password = '#{hashed_password}'", ["id = ?", user.id] )
      end
    end
  end

  def latest_news(options = {})
    News.latest_for self, options
  end

  def latest_projects(options = {})
    Project.latest_for self, options
  end

  protected

  # Password length validation based on setting
  def password_not_too_short
    minimum_length = Setting.password_min_length.to_i
    if !password.nil? && password.size < minimum_length
      errors.add(:password, :too_short, :count => minimum_length)
    end
  end

  private

  # Return password digest
  def self.hash_password(clear_password)
    Digest::SHA1.hexdigest(clear_password || "")
  end

  # Returns a 128bits random salt as a hex string (32 chars long)
  def self.generate_salt
    SecureRandom.hex(16)
  end

  def initialize_allowance_evaluators
    @registered_allowance_evaluators ||= self.class.registered_allowance_evaluators.collect do |evaluator|
      evaluator.new(self)
    end
  end

  def candidates_for_global_allowance
    @registered_allowance_evaluators.map(&:global_granting_candidates).flatten.uniq
  end

  def candidates_for_project_allowance project
    @registered_allowance_evaluators.map{ |f| f.project_granting_candidates(project) }.flatten.uniq
  end

  def reassign_associated
    substitute = DeletedUser.first

    [Issue, Attachment, WikiContent, News, Comment, Message].each do |klass|
      klass.update_all ['author_id = ?', substitute.id], ['author_id = ?', id]
    end

    [TimeEntry, Journal, ::Query].each do |klass|
      klass.update_all ['user_id = ?', substitute.id], ['user_id = ?', id]
    end

    foreign_keys = ['author_id', 'user_id', 'assigned_to_id']

    # as updating the journals will take some time we do it in batches
    # so that journals created later are also accounted for
    while (journal_subset = Journal.all(:conditions => ["id > ?", current_id ||= 0],
                                        :order => "id ASC",
                                        :limit => USER_DELETION_JOURNAL_BUCKET_SIZE)).size > 0 do

      journal_subset.each do |journal|
        change = journal.changed_data.dup

        foreign_keys.each do |foreign_key|
          if journal.changed_data[foreign_key].present?
            change[foreign_key] = change[foreign_key].map { |a_id| a_id == id ? substitute.id : a_id }
          end
        end

        journal.changed_data = change
        journal.save if journal.changed?
      end

      current_id = journal_subset.last.id
    end
  end

  def delete_associated_public_queries
    ::Query.delete_all ['user_id = ? AND is_public = ?', id, false]
  end
end

class AnonymousUser < User

  validate :validate_unique_anonymous_user, :on => :create

  # There should be only one AnonymousUser in the database
  def validate_unique_anonymous_user
    errors.add :base, 'An anonymous user already exists.' if AnonymousUser.find(:first)
  end

  def available_custom_fields
    []
  end

  # Overrides a few properties
  def logged?; false end
  def admin; false end
  def name(*args); I18n.t(:label_user_anonymous) end
  def mail; nil end
  def time_zone; nil end
  def rss_key; nil end
  def destroy; false end
end

class DeletedUser < User

  validate :validate_unique_deleted_user, :on => :create

  # There should be only one DeletedUser in the database
  def validate_unique_deleted_user
    errors.add :base, 'A DeletedUser already exists.' if DeletedUser.find(:first)
  end

  def self.first
    find_or_create_by_type_and_status(self.to_s, User::STATUS_BUILTIN)
  end

  # Overrides a few properties
  def logged?; false end
  def admin; false end
  def name(*args); I18n.t('user.deleted') end
  def mail; nil end
  def time_zone; nil end
  def rss_key; nil end
  def destroy; false end
end

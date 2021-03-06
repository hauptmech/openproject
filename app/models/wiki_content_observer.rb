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

class WikiContentObserver < ActiveRecord::Observer
  def after_create(wiki_content)
    if Setting.notified_events.include?('wiki_content_added')
      recipients = wiki_content.recipients + wiki_content.page.wiki.watcher_recipients
      users = User.find_all_by_mails(recipients.uniq)
      users.each do |user|
        UserMailer.wiki_content_added(user, wiki_content).deliver
      end
    end
  end

  def after_update(wiki_content)
    if wiki_content.text_changed? && Setting.notified_events.include?('wiki_content_updated')
      recipients = wiki_content.recipients + wiki_content.page.wiki.watcher_recipients + wiki_content.page.watcher_recipients
      users = User.find_all_by_mails(recipients.uniq)
      users.each do |user|
        UserMailer.wiki_content_updated(user, wiki_content).deliver
      end
    end
  end
end

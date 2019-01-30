-- Database abstractions
-- =====================
--
-- A cloud backend for Snap!
-- Written by Bernat Romagosa and Michael Ball
--
-- Copyright (C) 2019 by Bernat Romagosa and Michael Ball
--
-- This file is part of Snap Cloud.
--
-- Snap Cloud is free software: you can redistribute it and/or modify
-- it under the terms of the GNU Affero General Public License as
-- published by the Free Software Foundation, either version 3 of
-- the License, or (at your option) any later version.
--
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU Affero General Public License for more details.
--
-- You should have received a copy of the GNU Affero General Public License
-- along with this program.  If not, see <http://www.gnu.org/licenses/>.-

local Model = package.loaded.Model

package.loaded.Users = Model:extend('active_users', {
    primary_key = { 'username' },
    relations = {
        -- TODO: figure out why this does not work.
        -- { 'collections', has_many = 'Collections', key = 'creator_id' }
        { 'collections',
        fetch = function(self)
            return package.loaded.Collections:select('WHERE creator_id = ?', self.id)
        end
        },
        { 'public_collections',
        fetch = function(self)
            return package.loaded.Collections:select(
                'WHERE creator_id = ? AND published = true', self.id
            )
        end
        }
    },
    isadmin = function (self)
        return self.role == 'admin'
    end,
    isbanned = function (self)
        return self.role == 'banned'
    end,
    has_one_of_roles = function (self, roles)
        for _, role in pairs(roles) do
            if self.role == role then
                return true
            end
        end
        return false
    end,
    rollbar_params = function (self)
        -- just the info necessary for error tracking
        return { id = self.id, username = self.username }
    end
})

package.loaded.DeletedUsers = Model:extend('deleted_users', {
    primary_key = { 'username' }
})

package.loaded.Projects = Model:extend('active_projects', {
    primary_key = { 'username', 'projectname' }
})

package.loaded.DeletedProjects = Model:extend('deleted_projects', {
    primary_key = { 'username', 'projectname' }
})

package.loaded.Tokens = Model:extend('tokens', {
    primary_key = { 'value' }
})

package.loaded.Remixes = Model:extend('remixes', {
    primary_key = { 'original_project_id', 'remixed_project_id' }
})

package.loaded.Collections = Model:extend('collections', {
    primary_key = { 'creator_id', 'slug' },
    timestamp = true,
    relations = {
        -- TODO "projects", fetch() - get projects through memberships
        -- creates Collection:get_creator()
        { 'creator', belongs_to = 'Users', key = 'creator_id'}
    },
    constraints = {
        name = function(self, value)
            if not value then
                return 'A name must be present'
            end
        end,
        -- Ensure slugs are unique.
        slug = function(self, value, column, collection)
            if package.loaded.Collections:find({ slug = value }) ~= nil then
                return 'The name "' .. collection.name .. '" is already in use.'
            end
        end
    }
})

package.loaded.CollectionMemberships = Model:extend(
    'collection_memberships', {
    primary_key = { 'collection_id', 'project_id' },
    timestamp = true
})

-- Project API controller
-- ======================
--
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
-- along with this program.  If not, see <http://www.gnu.org/licenses/>.

local util = package.loaded.util
local validate = package.loaded.validate
local db = package.loaded.db
local cached = package.loaded.cached
local yield_error = package.loaded.yield_error
local cjson = require('cjson')

local Projects = package.loaded.Projects
local DeletedProjects = package.loaded.DeletedProjects
local Remixes = package.loaded.Remixes

require 'disk'
require 'responses'
require 'validation'

ProjectController = {
    GET = {
        projects = cached({
            -- GET /projects
            -- Description: Get a list of published projects.
            -- Parameters:  page, pagesize, matchtext, withthumbnail
            exptime = 30, -- cache expires after 30 seconds
            function (self)
                local query = 'where ispublished'

                -- Apply where clauses
                if self.params.matchtext then
                    query = query ..
                        db.interpolate_query(
                            ' and (projectname ~* ? or notes ~* ?)',
                            self.params.matchtext,
                            self.params.matchtext
                        )
                end

                local paginator =
                    Projects:paginated(
                        query .. ' order by firstpublished desc',
                        { per_page = self.params.pagesize or 16 }
                    )

                local projects = self.params.page and paginator:get_page(self.params.page) or paginator:get_all()

                processThumbnails(self, projects)

                return jsonResponse({
                    pages = self.params.page and paginator:num_pages() or nil,
                    projects = projects
                })
            end
        }),

        user_projects = function (self)
            -- GET /projects/:username
            -- Description: Get metadata for a project list by a user.
            --              Response will depend on parameters and query issuer permissions.
            -- Parameters:  ispublished, page, pagesize, matchtext, withthumbnail, updatingnotes
            local order = 'lastshared'

            if not (users_match(self)) then
                if not self.current_user or not self.current_user:isadmin() then
                    self.params.ispublished = 'true'
                    order = 'firstpublished'
                end
            end

            local query = db.interpolate_query('where username = ?', self.queried_user.username)

            -- Apply where clauses
            if self.params.ispublished ~= nil then
                query = query ..
                    db.interpolate_query(
                        ' and ispublished = ?',
                        self.params.ispublished == 'true'
                    )
            end

            if self.params.matchtext then
                query = query ..
                    db.interpolate_query(
                        ' and (projectname ~* ? or notes ~* ?)',
                        self.params.matchtext,
                        self.params.matchtext
                    )
            end

            local paginator = Projects:paginated(query .. ' order by ' .. order .. ' desc', { per_page = self.params.pagesize or 16 })
            local projects = self.params.page and paginator:get_page(self.params.page) or paginator:get_all()

            processNotes(self, projects)
            processThumbnails(self, projects)

            return jsonResponse({
                pages = self.params.page and paginator:num_pages() or nil,
                projects = projects,
            })
        end,

        project = function (self)
            -- GET /projects/:username/:projectname
            -- Description: Get a particular project.
            --              Response will depend on query issuer permissions.
            -- Parameters:  delta, ispublic, ispublished
            local project = Projects:find(self.params.username, self.params.projectname)

            if not project then yield_error(err.nonexistent_project) end
            if not (project.ispublic or users_match(self)) then assert_admin(self, err.not_public_project) end

            -- self.params.delta is a version indicator
            -- delta = null will fetch the current version
            -- delta = -1 will fetch the previous saved version
            -- delta = -2 will fetch the last version before today

            return rawResponse(
                -- if users don't match, this project is being remixed and we need to attach its ID
                '<snapdata' .. (users_match(self) and '>' or ' remixID="' .. project.id .. '">') ..
                (retrieve_from_disk(project.id, 'project.xml', self.params.delta) or '<project></project>') ..
                (retrieve_from_disk(project.id, 'media.xml', self.params.delta) or '<media></media>') ..
                '</snapdata>'
            )
        end,

        project_meta = function (self)
            -- GET /projects/:username/:projectname/metadata
            -- Description: Get a project metadata.
            -- Parameters:  projectname, ispublic, ispublished, lastupdated, lastshared
            local project = Projects:find(self.params.username, self.params.projectname)

            if not project then yield_error(err.nonexistent_project) end
            if not project.ispublic then assert_users_match(self, err.not_public_project) end

            local remixed_from = Remixes:select('where remixed_project_id = ?', project.id)[1]

            if remixed_from then
                if remixed_from.original_project_id then
                    local original_project = Projects:select('where id = ?', remixed_from.original_project_id)[1]
                    project.remixedfrom = {
                        username = original_project.username,
                        projectname = original_project.projectname
                    }
                else
                    project.remixedfrom = {
                        username = nil,
                        projectname = nil
                    }
                end
            end

            return jsonResponse(project)
        end,

        project_versions = function (self)
            -- GET /projects/:username/:projectname/versions
            -- Description: Get info about backed up project versions.
            -- Body:        versions
            local project = Projects:find(self.params.username, self.params.projectname)

            if not project then yield_error(err.nonexistent_project) end
            if not project.ispublic then assert_users_match(self, err.not_public_project) end

            -- seconds since last modification
            local query = db.select('extract(epoch from age(now(), ?::timestamp))', project.lastupdated)[1]

            return jsonResponse({
                {
                    lastupdated = query.date_part,
                    thumbnail = retrieve_from_disk(project.id, 'thumbnail') or
                        generate_thumbnail(project.id),
                    notes = parse_notes(project.id),
                    delta = 0
                },
                version_metadata(project.id, -1),
                version_metadata(project.id, -2)
            })
        end,

        project_remixes = function (self)
            -- GET /projects/:username/:projectname/remixes
            -- Description: Get a list of all published remixes from a project.
            -- Parameters:  page, pagesize
            local project = Projects:find(self.params.username, self.params.projectname)

            if not project then yield_error(err.nonexistent_project) end
            if not project.ispublic then assert_users_match(self, err.not_public_project) end

            local paginator =
                Remixes:paginated(
                    'where original_project_id = ?',
                    project.id,
                    { per_page = self.params.pagesize or 16 }
                )

            local remixes_metadata = self.params.page and paginator:get_page(self.params.page) or paginator:get_all()
            local remixes = {}

            for i, remix in pairs(remixes_metadata) do
                remixed_project = Projects:select('where id = ? and ispublished', remix.remixed_project_id)[1];
                if (remixed_project) then
                    -- Lazy Thumbnail generation
                    remixed_project.thumbnail =
                        retrieve_from_disk(remix.remixed_project_id, 'thumbnail') or
                            generate_thumbnail(remix.remixed_project_id)
                    table.insert(remixes, remixed_project)
                end
            end

            return jsonResponse({
                pages = self.params.page and paginator:num_pages() or nil,
                projects = remixes
            })
        end,

        project_thumbnail = cached({
            -- GET /projects/:username/:projectname/thumbnail
            -- Description: Get a project thumbnail.
            exptime = 30, -- cache expires after 30 seconds
            function (self)
                local project = Projects:find(self.params.username, self.params.projectname)
                if not project then yield_error(err.nonexistent_project) end

                if not users_match(self)
                    and not project.ispublic then
                    yield_error(err.auth)
                end

                -- Lazy Thumbnail generation
                return rawResponse(
                    retrieve_from_disk(project.id, 'thumbnail') or
                        generate_thumbnail(project.id))
            end
        })
    },

    POST = {
        project = function (self)
            -- POST /projects/:username/:projectname
            -- Description: Add/update a particular project.
            --              Response will depend on query issuer permissions.
            -- Body:        xml, notes, thumbnail
            validate.assert_valid(self.params, {
                { 'projectname', exists = true },
                { 'username', exists = true }
            })

            assert_all({assert_user_exists, assert_users_match}, self)

            -- Read request body and parse it into JSON
            ngx.req.read_body()
            local body_data = ngx.req.get_body_data()
            local body = body_data and util.from_json(body_data) or nil

            if (not body.xml) then
                yield_error('Empty project contents')
            end

            local project = Projects:find(self.params.username, self.params.projectname)

            if (project) then
                local shouldUpdateSharedDate =
                    ((not project.lastshared and self.params.ispublic)
                    or (self.params.ispublic and not project.ispublic))

                backup_project(project.id)

                project:update({
                    lastupdated = db.format_date(),
                    lastshared = shouldUpdateSharedDate and db.format_date() or nil,
                    firstpublished =
                        project.firstpublished or
                        (self.params.ispublished and db.format_date()) or
                        nil,
                    notes = body.notes,
                    ispublic = self.params.ispublic or project.ispublic,
                    ispublished = self.params.ispublished or project.ispublished
                })
            else
                -- Users are automatically verified the first time
                -- they save a project
                if (not self.queried_user.verified) then
                    self.queried_user:update({ verified = true })
                    self.session.verified = true
                end

                -- A project flagged as "deleted" with the same name may exist in the DB.
                -- We need to check for that and delete it for real this time
                local deleted_project = DeletedProjects:find(self.params.username, self.params.projectname)
                if deleted_project then deleted_project:delete() end

                Projects:create({
                    projectname = self.params.projectname,
                    username = self.params.username,
                    created = db.format_date(),
                    lastupdated = db.format_date(),
                    lastshared = self.params.ispublic and db.format_date() or nil,
                    firstpublished = self.params.ispublished and db.format_date() or nil,
                    notes = body.notes,
                    ispublic = self.params.ispublic or false,
                    ispublished = self.params.ispublished or false
                })
                project = Projects:find(self.params.username, self.params.projectname)

                if (body.remixID and body.remixID ~= cjson.null) then
                    -- user is remixing a project
                    Remixes:create({
                        original_project_id = body.remixID,
                        remixed_project_id = project.id,
                        created = db.format_date()
                    })
                end
            end

            save_to_disk(project.id, 'project.xml', body.xml)
            save_to_disk(project.id, 'thumbnail', body.thumbnail)
            save_to_disk(project.id, 'media.xml', body.media)

            if not (retrieve_from_disk(project.id, 'project.xml')
                and retrieve_from_disk(project.id, 'thumbnail')
                and retrieve_from_disk(project.id, 'media.xml')) then
                yield_error('Could not save project ' .. self.params.projectname)
            else
                return okResponse('project ' .. self.params.projectname .. ' saved')
            end
        end,

        project_meta = function (self)
            -- POST /projects/:username/:projectname/metadata
            -- Description: Get/add/update a project metadata.
            -- Parameters:  projectname, ispublic, ispublished, lastupdated, lastshared
            -- Body:        notes, projectname
            if not users_match(self) then assert_admin(self) end

            if self.current_user:isbanned() and self.params.ispublished then
                yield_error(err.banned)
            end

            local project = Projects:find(self.params.username, self.params.projectname)
            if not project then yield_error(err.nonexistent_project) end

            local shouldUpdateSharedDate =
                ((not project.lastshared and self.params.ispublic)
                or (self.params.ispublic and not project.ispublic))

            -- Read request body and parse it into JSON
            ngx.req.read_body()
            local body_data = ngx.req.get_body_data()
            local body = body_data and util.from_json(body_data) or nil
            local new_name = body and body.projectname or nil
            local new_notes = body and body.notes or nil
            
            -- save new notes and project name into the project XML
            if new_notes then update_notes(project.id, new_notes) end
            if new_name then update_name(project.id, new_name) end

            project:update({
                projectname = new_name or project.projectname,
                lastupdated = db.format_date(),
                lastshared = shouldUpdateSharedDate and db.format_date() or nil,
                firstpublished =
                    project.firstpublished or
                    (self.params.ispublished and db.format_date()) or
                    nil,
                notes = new_notes or project.notes,
                ispublic = self.params.ispublic or project.ispublic,
                ispublished = self.params.ispublished or project.ispublished
            })

            return okResponse('project ' .. self.params.projectname .. ' updated')
        end
    },

    DELETE = {
        project = function (self)
            -- DELETE /projects/:username/:projectname
            -- Description: Delete a particular project.
            --              Response will depend on query issuer permissions.
            assert_all({'project_exists', 'user_exists'}, self)
            if not users_match(self) then assert_admin(self) end

            local project = Projects:find(self.params.username, self.params.projectname)

            --[[
            local id = project.id

            -- Check out whether this project was a remix of some other project, then delete the remix
            local remix = Remixes:select('where remixed_project_id = ?', id)[1]
            if remix then remix:delete() end

            -- Check out whether this project has been remixed by other projects, then orphan these remixes
            local query = db.query('update remixes set original_project_id = null where original_project_id = ?', id);

            if not (project:delete()) then
                yield_error('Could not delete project ' .. self.params.projectname)
            else
                delete_directory(id)
                return okResponse('Project ' .. self.params.projectname .. ' has been removed.')
            end
            ]]--

            -- Do not actually delete the project; flag it as deleted.

            if not (project:update({ deleted = db.format_date() })) then
                yield_error('Could not delete project ' .. self.params.projectname)
            else
                return okResponse('Project ' .. self.params.projectname .. ' has been removed.')
            end
        end
    }
}

-- Utility functions

function processNotes (self, projects)
    -- Lazy Notes generation
    if self.params.updatingnotes == 'true' then
        for _, project in pairs(projects) do
            if (project.notes == nil) then
                local notes = parse_notes(project.id)
                if notes then
                    project:update({ notes = notes })
                    project.notes = notes
                end
            end
        end
    end
end

function processThumbnails (self, projects)
    -- Lazy Thumbnail generation
    if self.params.withthumbnail == 'true' then
        for _, project in pairs(projects) do
            project.thumbnail =
                retrieve_from_disk(project.id, 'thumbnail') or
                    generate_thumbnail(project.id)
        end
    end
end
========
 Hotels
========

---------
 Summary
---------

The hotel booking workflow consists of three mandatory steps.

 1. :ref:`Hotel_Search`
 2. :ref:`Hotel_Details`
 3. :ref:`Hotel_Booking`

Additional calls that are available:

 - :ref:`Hotel_Room_Details`

.. _Hotel_Search:

--------
 Search
--------

Request
=======

.. http:post:: /hotels

    Searches for hotels that match provided criteria.

    :JSON Parameters:
        - **cityCode** (*String*) -- city to search for a hotel in, given as
          its IATA code
        - **arrivalDate** (*String*) -- date when the occupants arrive, in ISO
          format, not including a time code (ex. 2014-12-24)
        - **leaveDate** (*String*) -- date when the occupants arrive, in ISO
          format, not including a time code (ex. 2014-12-26)
        - **occupancy** (*Integer*) -- number of people wanting to book a room

Response Body
=============

    :JSON Parameters:
        - **hotelResultSet** (:ref:`hotel-result` *\[ \]*) -- root container

.. _hotel-result:

Hotel
-----

Response Codes
==============

 - **404 'No hotels available'**

Examples
========

Request
-------

    **JSON:**

    .. sourcecode:: json

        {
          "cityCode": "LON",
          "occupancy": 1,
          "arrivalDate": "2014-09-29",
          "leaveDate": "2014-09-30"
        }

Response
--------

    **JSON:**

    .. sourcecode:: json

        {
          ...
        }

.. _Flight_Details:

---------
 Details
---------

Request
=======

.. http:get:: /hotels/:hotel_id

    **hotel_id** is the ID of the :ref:`hotel-result` to get the details of

Response Body
=============

    :JSON Parameters:
        - **hotel_details** (:ref:`HotelDetailsContainer`) -- root container

.. _HotelDetailsContainer:

HotelDetails
------------

    :JSON Parameters:
        - **chain_code** (*String*) --
        - **chain_name** (*String*) --
        - **hotel_code** (*String*) --
        - **hotel_name** (*String*) --
        - **location** (:ref:`HotelLocation`) -- contains info about the
          hotel's location.
        - **points_of_interest** (:ref:`POI` *\[ \]*) -- contains a list
          of notable locations around the hotel
        - **description** (*String*) -- A short text describing the hotel
        - **contact_info** (*HotelContactInfo*) --
          - **phone_numbers** (*String \[ \]*) --
          - **email** (*String*) --
          - **website** (*String*) --
        - **price** (*PriceRange*) -- contains the lowest and highest rates
          available for a room at this hotel
          - **minimum** (*Float*) -- Rate of the cheapest room at the hotel
          - **maximum** (*Float*) -- Rate of the most expensive room at the
            hotel
          - **currency** (*String*) --
        - **thumbnail** (*String*) -- Contains a URL pointing to a small
          image of the hotel
        - **photos** (*String \[ \]*) -- Contains an array of URLs pointing
          to a larger photos of the hotel
        - **amenities** (*Amenities*) -- Contains an associative array,
          mapping each amenity listed below to a boolean value based on
          whether the hotel has given amenity. List of keys: 'restaurant',
          'bar', 'laundry', 'room_service', 'safe_deposit_box', 'parking',
          'swimming', 'internet', 'gym', 'air_conditioning',
          'business_center', meeting_rooms', 'spa', 'pets_allowed'
        - **stars** (*Integer*) -- Contains the amount of stars this hotel
          has been awarded.
        - **rules** (*Rules*) -- Contains an associative array, mapping each
          rule type listed below to the relevant text. List of keys:
          'guarantee', 'safety', 'extra_occupants', 'policy', 'charges',
          'deposit', 'meals', 'stay', 'tax'
        - **rooms** (:ref:`Room` *\[ \]*) -- contains the available rooms

.. _HotelLocation:

HotelLocation
-------------

    :JSON Parameters:
        - **country** (*String*) --
        - **state** (*String*) --
        - **city** (*String*) --
        - **address** (*String*) --
        - **zip_code** (*String*) --
        - **area** (*String*) -- one of: 'north', 'east', 'south', 'west',
          'downtown', 'airport', 'resort'
        - **recommended_transport** (*String*) -- one of: 'boat', 'coach',
          'train', 'free', 'helicopter', 'limousine', 'plane', 'rental car',
          'taxi', 'subway', 'walking'

.. _Room:

Room
----

    :JSON Parameters:
        - **room_id** (*String*) -- ID of the room in question
        - **booking_id** (*String*) -- ID to use when booking this room
        - **price** (*RoomPrice*) -- Contains data about the price of the room
          - **amount** (*Float*) --
          - **covers** (*String*) -- One of 'day' or 'trip', specifies which
            duration the price covers
          - **rate_varies** (*Boolean*) -- True if the rate is not going to be
            the same for each day during the occupant's stay. In this case,
            the above given amount is the highest one during the trip.
        - **room_type** (*Traits*) -- Contains the traits of the given room,
          including the category, bed/shower availability, whether smoking is
          allowed, and whether it is a suite. The keys are the following:
          'bath', 'shower', 'nonsmoking', 'suite', 'category'. The first four
          have boolean values, while 'category' can be one of: 'minimum',
          'standard', 'moderate', 'superior', 'executive'
        - **bed_type** (*String*) -- One of: 'single', 'double', 'twin',
          'king size', 'queen size', 'pullout', 'water bed'
        - **description** (*String*) -- Contains a short text about the room
        - **quantity** (*Integer*) -- Contains the amount left to be booked of
          this room

Examples
========

Response
--------

    **JSON:**

    .. sourcecode:: json

        {
          ...
        }

.. _Hotel_Room_Details:

--------------
 Room Details
--------------

Request
=======

.. http:get:: /hotels/:hotel_id/rooms/:room_id

    **hotel_id** is the ID of the :ref:`hotel-result` the room belongs to,
    **room_id** is the ID of the :ref:`Room` to get the details of.

Response Body
=============

    :JSON Parameters:
        - **hotel_room_details** (:ref:`HotelRoomDetailsContainer`) -- root
          container

.. _HotelRoomDetailsContainer:

HotelRoomDetails
----------------

    :JSON Parameters:
        - **rules** (*Rules*) -- Contains an associative array, mapping each
          rule type listed below to the relevant text, or a relevant boolean
          value. List of keys: 'cancellation', 'notes', 'needs_guarantee',
          'needs_deposit'
        - **price** (*RoomPrice*) --
          - **amount** (*Float*) --
          - **includes** (*String \[ \]*) -- Contains what services or extras
            are included in the price.

Examples
========

Response
--------

    **JSON:**

    .. sourcecode:: json

        {
          ...
        }

.. _Hotel_Booking:

---------
 Booking
---------

Request
=======

.. http:post:: /books

    :JSON Parameters:
        - **bookBasket** (*String \[ \]*) -- an array containing only the
          booking ID of the :ref:`Room` to book
        - **billingInfo** (:ref:`Contact`) -- billing info for the booking
        - **contactInfo** (:ref:`Contact`) -- contact info for the booking
        - **persons** (:ref:`Person` *\[ \]*) -- the list of occupants

.. _Contact:

Contact
-------

    :JSON Parameters:
        - **address** (:ref:`Address`) -- address of the entity in question
        - **email** (*String*) -- email of the entity in question
        - **name** (*String*) -- name of the entity in question
        - **phone** (:ref:`Phone`) -- phone number of the entity in question

.. _Address:

Address
-------

    :JSON Parameters:
        - **addressLine1** (*String*)
        - **addressLine2** (*String*) -- *(optional)*
        - **addressLine3** (*String*) -- *(optional)*
        - **cityName** (*String*)
        - **zipCode** (*String*)
        - **countryCode** (*String*) -- the two letter code of the country

.. _Phone:

Phone
-----

    :JSON Parameters:
        - **countryCode** (*Integer*)
        - **areaCode** (*Integer*)
        - **phoneNumber** (*Integer*)

.. _Person:

Person
------

    :JSON Parameters:
        - **birthDate** (*String*) -- format is ``YYYY-MM-DD``
        - **email** (*String*)
        - **namePrefix** (*String*) -- one of ``Mr``, ``Ms``, or ``Mrs``
        - **firstName** (*String*)
        - **lastName** (*String*)
        - **gender** (*String*) -- one of ``MALE`` or ``FEMALE``

Response Body
=============

Examples
========

Request
-------

    **JSON:**

    .. sourcecode:: json

        {
          "bookBasket": ["1_0/2_0"],
          "billingInfo": {
            "address": {
              "addressLine1": "Váci út 13-14",
              "cityName": "Budapest",
              "countryCode": "HU",
              "zipCode": "1234"
            },
            "email": "ccc@gmail.com",
            "name": "Kovacs Gyula",
            "phone": {
              "areaCode": 30,
              "countryCode": 36,
              "phoneNumber": 1234567
            }
          },
          "contactInfo": {
            "address": {
              "addressLine1": "Váci út 13-14",
              "cityName": "Budapest",
              "countryCode": "HU"
            },
            "email": "bbb@gmail.com",
            "name": "Kovacs Lajos",
            "phone": {
              "areaCode": 30,
              "countryCode": 36,
              "phoneNumber": 1234567
            }
          },
          "passengers": [
            {
              "birthDate": "1974-04-03",
              "email": "aaa@gmail.com",
              "firstName": "Janos",
              "gender": "MALE",
              "lastName": "Kovacs",
              "namePrefix": "Mr"
            }
          ]
        }

Response
--------

    **JSON:**

    .. sourcecode:: json

        {
          ...
        }

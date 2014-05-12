=========
 Flights 
=========

--------
 Search
--------

Request
=======

.. http:post:: /flights/

    Searches for flights that match provided criteria.

    :jsonparam String fromLocation: departure location, given as IATA code
    :jsonparam String toLocation: destination, given as IATA code
    :jsonparam Date departureDate: date of departure, in ISO format *(including
                                   a time code, even though whole day will be 
                                   searched by default)*
    :jsonparam Date returnDate: date of return, in ISO format *(including
                                a time code, even though whole day will be 
                                searched by default)*
    :jsonparam Array persons: a list of passengers, grouped by type code 
        :ref:`Person`
    :jsonparam String fromAirport: *(optional)* departure airport, given as
                                   IATA code, must be in the city specified in
                                   ``fromLocation``
    :jsonparam String toAirport: *(optional)* destination airport, given as
                                 IATA code, must be in the city specified in
                                 ``toLocation``
    :jsonparam String providerType: *(optional)* type of results to retrieve
    :jsonparam Array airlines: *(optional)* list of airlines to filter results
                              to, given as their IATA code

.. _Person:

Person object
-------------



Response
========

Examples
========

Request
-------

    **JSON:**

    .. sourcecode:: json

        {}

Response
--------

    **JSON:**

    .. sourcecode:: json

        {}

